%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @copyright (C) 2022, Tony Rogvall
%%% @doc
%%%    Charge amps REST client
%%% @end
%%% Created : 26 Sep 2022 by Tony Rogvall <tony@rogvall.se>
%%%-------------------------------------------------------------------
-module(charge_amps).

-behaviour(gen_server).

%% API
-export([start/0]).
-export([start_link/0, start_link/1]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3, format_status/2]).

-export([login/1, refresh/1, last_refresh/1, token/1]).

-export([get_owned/1]).
-export([get_chargepoint/2]).
-export([get_status/2]).
-export([get_settings/2, get_settings/3]).
-export([set_settings/4]).

%% schedules
-export([get_schedules/2, get_schedules/3]).
-export([set_schedules/3]).
-export([create_schedule/3]).
-export([delete_schedule/3]).

%% example:
%%   turn charger on/off
%%   charge_amps:set_settings("joe@mail.com", "1111000000M", "1", #{ mode => <<"On">>}).
%%   charge_amps:set_settings("joe@mail.com", "1111000000M", "1", #{ mode => <<"Off">>}).
%%


-include_lib("kernel/include/file.hrl").
-include_lib("rester/include/rester_http.hrl").


-define(SERVER, ?MODULE).
-define(APP, ?MODULE).

-define(SECONDS(X), ((X)*1000)).
-define(MINUTES(X), ?SECONDS(60)).
-define(HOURS(X), ?MINUTES(60)).

-define(TOKEN_TIMEOUT, ?MINUTES(120)).  %% after 120s (2 hours) refresh
-define(REFRESH_TIMEOUT, ?HOURS(168)).  %% after 168h (7 days) login

-define(DEFAULT_URL, "https://eapi.charge.space").
-define(API, "/api/v4").

-define(DEFAULT_API_DIR, "${HOME}/.charge_amps").
-define(DEFAULT_ACCOUNT_DIR(ApiDir,Key), ApiDir++"/"++Key).
-define(DEFAULT_API_KEY_FILENAME(Dir), (Dir)++"/api_key").
-define(DEFAULT_PASSWORD_FILENAME(Dir), (Dir)++"/password").
-define(DEFAULT_TOKEN_FILENAME(Dir), (Dir)++"/token").
-define(DEFAULT_REFRESH_TOKEN_FILENAME(Dir), (Dir)++"/refresh_token").

-define(is_id(X),
	(is_list((X)) orelse is_binary((X)) orelse is_atom((X)))).

-record(account, 
	{
	 email :: binary(),
	 password_filename  :: undefined | file:filename(),
	 password :: undefined | file | binary(),

	 api_key_filename :: undefined | file:filename(),
	 api_key :: undefined | file | binary(),

	 token_filename :: file:filename(),
	 token :: binary(),

	 refresh_token_filename :: file:filename(),
	 refresh_token :: binary(),
	 
	 refresh_datetime :: calendar:datetime()
	}).

-record(state, 
	{
	 url :: string(),
	 api_dir :: file:filename(),
	 accounts :: #{ Email::string() => #account{} }
	}).

%%%===================================================================
%%% API
%%%===================================================================
start() -> 
    io:format("charge_amps: start\n", []),
    application:ensure_all_started(?MODULE).

login(AccountKey) -> gen_server:call(?SERVER, {login,AccountKey}).
refresh(AccountKey) -> gen_server:call(?SERVER, {refresh,AccountKey}).
last_refresh(AccountKey) -> gen_server:call(?SERVER,{last_refresh,AccountKey}).
token(AccountKey) -> gen_server:call(?SERVER,{token,AccountKey}).
    
%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, Pid :: pid()} |
	  {error, Error :: {already_started, pid()}} |
	  {error, Error :: term()} |
	  ignore.

start_link() ->
    io:format("charge_amps: start_link()\n", []),
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec start_link([{Key::atom(),Value::term()}]) -> {ok, Pid :: pid()} |
	  {error, Error :: {already_started, pid()}} |
	  {error, Error :: term()} |
	  ignore.
start_link(Args) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Args, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, State :: term()} |
	  {ok, State :: term(), Timeout :: timeout()} |
	  {ok, State :: term(), hibernate} |
	  {stop, Reason :: term()} |
	  ignore.
init(Args0) ->
    Args = Args0 ++ application:get_all_env(?APP),
    process_flag(trap_exit, true),
    Url = proplists:get_value(url, Args, ?DEFAULT_URL),
    ApiDir = proplists:get_value(api_dir, Args, ?DEFAULT_API_DIR),
    %% load all accounts 
    AccountList = proplists:get_value(accounts, Args, []),
    %% Create a map from user (email) => #account{}
    Accounts =
	lists:foldl(
	  fun({account,Acc}, Map) ->
		  %% mandatory
		  Key0 = Email = proplists:get_value(email,Acc),
		  Key = to_string(Key0),
		  Dir = proplists:get_value(dir,Acc,
					    ?DEFAULT_ACCOUNT_DIR(ApiDir,Key)),
		  PasswordFilename = proplists:get_value(password_filename,Acc,
						     ?DEFAULT_PASSWORD_FILENAME(Dir)),
		  Password1 = proplists:get_value(password,Acc,undefined),
		  Password = case Password1 of
				 file -> file;
				 undefined ->
				     case read_file(PasswordFilename) of
					 {ok,Password2} -> Password2;
					 {error, enoent} -> undefined
				     end;
				 Pass -> to_binary(Pass)
			     end,
		  ApiKeyFilename = 
		      proplists:get_value(api_key_filename,Acc,
					  ?DEFAULT_API_KEY_FILENAME(Dir)),
		  ApiKey0 = proplists:get_value(api_key,Acc,undefined),
		  ApiKey = case ApiKey0 of
			       file -> file;
			       undefined ->
				   case read_file(ApiKeyFilename) of
				       {ok,ApiKey2} -> ApiKey2;
				       {error, enoent} -> <<>>
				   end;
			       ApiKey3 -> to_binary(ApiKey3)
			   end,
		  TokenFilename = proplists:get_value(token_filename,Acc,
						      ?DEFAULT_TOKEN_FILENAME(Dir)),
		  Token = case read_file(TokenFilename) of
			      {ok,Token0} -> Token0;
			      {error, enoent} -> 
				  to_binary(proplists:get_value(token,Acc,<<>>))
			  end,
		  RefreshTokenFilename = proplists:get_value(refresh_token_filename,Acc,?DEFAULT_REFRESH_TOKEN_FILENAME(Dir)),
		  RefreshToken = case read_file(RefreshTokenFilename) of
				     {ok,RefreshToken0} -> RefreshToken0;
				     {error, enoent} ->
					 to_binary(proplists:get_value(refresh_token,Acc,<<>>))
				 end,
		  DateTime = 
		      case proplists:get_value(refresh_datetime,Acc,never) of
			  never ->
			      %% load from refresh_token_filename
			      file_mod(RefreshTokenFilename);
			  DT = {{_,_,_},{_,_,_}} -> DT
		      end,

		  Account = #account { email = Email,
				       password_filename = PasswordFilename,
				       password = Password,
				       api_key_filename = ApiKeyFilename,
				       api_key = ApiKey,
				       token_filename = TokenFilename,
				       token = Token,
				       refresh_token_filename = RefreshTokenFilename,
				       refresh_token = RefreshToken,
				       refresh_datetime = DateTime
				     },
		  Map#{ to_binary(Key) => Account }
	  end, #{}, AccountList),
    
    {ok, #state{ 
	    url = Url,
	    api_dir = ApiDir,
	    accounts = Accounts
	   }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, State :: term()) ->
	  {reply, Reply :: term(), NewState :: term()} |
	  {reply, Reply :: term(), NewState :: term(), Timeout :: timeout()} |
	  {reply, Reply :: term(), NewState :: term(), hibernate} |
	  {noreply, NewState :: term()} |
	  {noreply, NewState :: term(), Timeout :: timeout()} |
	  {noreply, NewState :: term(), hibernate} |
	  {stop, Reason :: term(), Reply :: term(), NewState :: term()} |
	  {stop, Reason :: term(), NewState :: term()}.

handle_call({token,AccountKey}, _From, State) ->
    Accounts = State#state.accounts,
    Key = to_binary(AccountKey),
    case maps:get(Key, Accounts, undefined) of
	undefined ->
	    {reply, {error,no_such_account}, State};
	Account ->
	    {reply, {ok,{State#state.url++?API,Account#account.token}}, State}
    end;

handle_call({login,AccountKey}, _From, State) ->
    %% FIXME: async!
    Accounts = State#state.accounts,
    Key = to_binary(AccountKey),
    case maps:get(Key, Accounts, undefined) of
	undefined ->
	    {reply, {error,no_such_account}, State};
	Account = #account { email=EMail} ->
	    Url = State#state.url ++ ?API ++ "/auth/login",
	    {ok,Password} = read_password(Account),
	    {ok,ApiKey} = read_apikey(Account),
	    case rester_http:wpost(Url,
				   [{'apiKey', ApiKey},
				    {'Accept',"application/json"},
				    {'Content-Type',"application/json"}],
				   #{ <<"email">> => EMail,
				      <<"password">> => Password}) of
		{ok,Resp,Body} when Resp#http_response.status =:= 200 ->
		    B = jsone:decode(Body),
		    Token = maps:get(<<"token">>, B, <<"">>),
		    write_file(Account#account.token_filename, Token),
		    RefreshToken = maps:get(<<"refreshToken">>, B, <<"">>),
		    write_file(Account#account.refresh_token_filename, 
			       RefreshToken),
		    User = maps:get(<<"user">>, B, <<"">>),
		    Account1 = Account#account {token = Token, 
						refresh_token = RefreshToken },
		    Accounts1 = Accounts#{ Key => Account1 },
		    {reply, {ok,User}, State#state { accounts = Accounts1 }};
		{ok,Resp,Body} ->
		    B = jsone:decode(Body),
		    {reply, {error,Resp#http_response.status,B}, State};
		Error={error,_} ->
		    {reply, Error, State}
	    end
    end;

handle_call({refresh,AccountKey}, _From, State) ->
    %% FIXME: async!
    Accounts = State#state.accounts,
    Key = to_binary(AccountKey),
    case maps:get(Key, Accounts, undefined) of
	undefined ->
	    {reply, {error,no_such_account}, State};
	Account = #account { token=Token, refresh_token=Refresh } ->
	    Url = State#state.url ++ ?API ++ "/auth/refreshtoken",
	    case rester_http:wpost(Url,
				   [{'Authorization', ["Bearer ",Token]},
				    {'Accept',"application/json"},
				    {'Content-Type',"application/json"}],
				   #{ <<"token">> => Token,
				      <<"refreshToken">> => Refresh}) of
		{ok,Resp,Body} when Resp#http_response.status =:= 200 ->
		    B = jsone:decode(Body),
		    Token1 = maps:get(<<"token">>, B, <<"">>),
		    write_file(Account#account.token_filename, Token1),
		    Refresh1 = maps:get(<<"refreshToken">>, B, <<"">>),
		    write_file(Account#account.refresh_token_filename, 
			       Refresh1),
		    Account1 = Account#account {token = Token1, 
						refresh_token = Refresh1 },
		    Accounts1 = Accounts#{ Key => Account1 },
		    {reply, {ok,Token1}, State#state { accounts = Accounts1 }};
		{ok,Resp,Body} ->
		    B = jsone:decode(Body),
		    {reply, {error,Resp#http_response.status,B}, State};
		Error ->
		    {reply, Error, State}
	    end
    end;
    
handle_call({last_refresh,AccountKey}, _From, State) ->
    Accounts = State#state.accounts,
    Key = to_binary(AccountKey),
    case maps:get(Key, Accounts, undefined) of
	undefined ->
	    {reply, {error,no_such_account}, State};
	Account ->
	    When = seconds_since_mod(Account#account.refresh_token_filename),
	    {reply, When, State}
    end;

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), State :: term()) ->
	  {noreply, NewState :: term()} |
	  {noreply, NewState :: term(), Timeout :: timeout()} |
	  {noreply, NewState :: term(), hibernate} |
	  {stop, Reason :: term(), NewState :: term()}.
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), State :: term()) ->
	  {noreply, NewState :: term()} |
	  {noreply, NewState :: term(), Timeout :: timeout()} |
	  {noreply, NewState :: term(), hibernate} |
	  {stop, Reason :: normal | term(), NewState :: term()}.
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
		State :: term()) -> any().
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
		  State :: term(),
		  Extra :: term()) -> {ok, NewState :: term()} |
	  {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
		    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% API functions
%%%===================================================================

get_owned(AccountKey) ->
    Path = "/chargepoints/owned",
    wget(AccountKey, Path).

get_chargepoint(AccountKey, Arg) ->
    case to_string(Arg) of
	false -> {error, badarg};
	ChargePointId ->
	    Path = "/chargepoints/" ++ ChargePointId,
	    wget(AccountKey, Path)
    end.

get_status(AccountKey, Arg1) ->
    case to_string(Arg1) of
	false ->
	    {error, badarg};
	ChargePointId ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/status",
	    wget(AccountKey, Path)
    end.

get_settings(AccountKey, Arg1) ->
    case to_string(Arg1) of
	false ->
	    {error, badarg};
	ChargePointId ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/settings",
	    wget(AccountKey, Path)
    end.
get_settings(AccountKey,Arg1,Arg2) ->
    case {to_string(Arg1),to_string(Arg2)} of
	{false,_} -> {error, badarg};
	{_,false} -> {error, badarg};
	{ChargePointId,ConnectorId} ->
	    Path = "/chargepoints/" ++ 
		ChargePointId ++ "/connectors/"++
		ConnectorId++"/settings",
	    wget(AccountKey, Path)
    end.

set_settings(AccountKey,Arg1,Arg2,Settings) ->
    case {to_string(Arg1),to_string(Arg2)} of
	{false,_} ->
	    {error, badarg};
	{_,false} ->
	    {error, badarg};
	{ChargePointId,ConId} ->
	    Path = "/chargepoints/" ++ 
		ChargePointId ++ "/connectors/"++ConId++"/settings",
	    wput(AccountKey, Path, Settings)
    end.

get_schedules(AccountKey,Arg1) ->
    case to_string(Arg1) of
	false -> {error,badarg};
	ChargePointId ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/schedules",
	    wget(AccountKey, Path)
    end.
get_schedules(AccountKey,Arg1,Arg2) ->
    case {to_string(Arg1),to_string(Arg2)} of
	{false,_} -> {error, badarg};
	{_,false} -> {error, badarg};
	{ChargePointId,ScheduleId} ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/schedules/" ++
		ScheduleId,
	    wget(AccountKey, Path)
    end.

set_schedules(AccountKey,Arg1,Schedule) ->
    case to_string(Arg1) of
	false -> {error, badarg};
	ChargePointId ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/schedules",
	    wput(AccountKey, Path, Schedule)
    end.

create_schedule(AccountKey,Arg1,Schedule) ->
    case to_string(Arg1) of
	false -> {error, badarg};
	ChargePointId ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/schedules",
	    wpost(AccountKey, Path, Schedule)
    end.

delete_schedule(AccountKey,Arg1,Arg2) ->
    case {to_string(Arg1),to_string(Arg2)} of
	{false,_} -> {error, badarg};
	{_,false} -> {error, badarg};
	{ChargePointId,ScheduleId} ->
	    Path = "/chargepoints/" ++ ChargePointId ++ "/schedules/" ++
		ScheduleId,
	    wdelete(AccountKey, Path)
    end.

%% Get request with refresh/login if needed
wget(AccountKey, Path) -> wget(AccountKey, Path, []).
wget(AccountKey, Path, Hs) ->
    {ok,{ApiUrl,Token}} = token(AccountKey),
    wget_(AccountKey, Token, ApiUrl ++ Path, Hs, 1).
    
wget_(AccountKey, Token, Url, Hs, Attempt) when Attempt < 3 ->
    case rester_http:wget(Url,
			  [{'Authorization', ["Bearer ", Token]},
			   {'Accept',"application/json"} | Hs]) of
	{ok,Resp,Body} when Resp#http_response.status =:= 200 ->
	    {ok,jsone:decode(Body)};
	{error, closed} -> %% may happend when retreive stale socket from cache
	    %% does this count as an attempt? fixme...
	    wget_(AccountKey, Token, Url, Hs, Attempt+1);
	{ok,Resp,_Body} when Resp#http_response.status =:= 401 ->
	    case refresh(AccountKey) of
		{ok,Token1} ->
		    %% timer:sleep(2000),  %% wait a while...
		    %% cache_close(Url),
		    wget_(AccountKey, Token1, Url, Hs, Attempt+1);
		Error ->
		    Error
	    end;
	{ok,Resp,Body} ->
	    %% B = jsone:decode(Body),
	    {error,Resp#http_response.status,Body};
	Error ->
	    Error
    end;
wget_(_AccountKey, _Token, _Url, _Hs, _Attempt) ->
    {error, too_many_attempts}.


%% Get request with refresh/login if needed
wput(AccountKey, Path, Data) -> wput(AccountKey, Path, Data, []).
wput(AccountKey, Path, Data, Hs) ->
    {ok,{ApiUrl,Token}} = token(AccountKey),
    wput_(AccountKey, Token, ApiUrl ++ Path, Data, Hs, 1).
    
wput_(AccountKey, Token, Url, Data, Hs, Attempt) when Attempt < 3 ->
    case rester_http:wput(Url,
			  [{'Authorization', ["Bearer ", Token]},
			   {'Content-Type',"application/json"},
			   {'Accept',"application/json"} | Hs], Data) of
	{ok,Resp,Body} when Resp#http_response.status =:= 200 ->
	    {ok,Body};
	{error, closed} -> %% may happend when retreive stale socket from cache
	    %% does this count as an attempt? fixme...
	    wput_(AccountKey, Token, Url, Data, Hs, Attempt+1);
	{ok,Resp,_Body} when Resp#http_response.status =:= 401 ->
	    case refresh(AccountKey) of
		{ok,Token1} ->
		    %% timer:sleep(2000),  %% wait a while...
		    %% cache_close(Url),
		    wput_(AccountKey, Token1, Url, Data, Hs, Attempt+1);
		Error ->
		    Error
	    end;
	{ok,Resp,Body} ->
	    %% B = jsone:decode(Body),
	    {error,Resp#http_response.status,Body};
	Error ->
	    Error
    end;
wput_(_AccountKey, _Token, _Url, _Data, _Hs, _Attempt) ->
    {error, too_many_attempts}.


wpost(AccountKey, Path, Data) -> wpost(AccountKey, Path, Data, []).
wpost(AccountKey, Path, Data, Hs) ->
    {ok,{ApiUrl,Token}} = token(AccountKey),
    wpost_(AccountKey, Token, ApiUrl ++ Path, Data, Hs, 1).
    
wpost_(AccountKey, Token, Url, Data, Hs, Attempt) when Attempt < 3 ->
    case rester_http:wpost(Url,
			   [{'Authorization', ["Bearer ", Token]},
			    {'Content-Type',"application/json"},
			    {'Accept',"application/json"} | Hs], Data) of
	{ok,Resp,Body} when Resp#http_response.status =:= 200 ->
	    {ok,Body};
	{error, closed} -> %% may happend when retreive stale socket from cache
	    %% does this count as an attempt? fixme...
	    wpost_(AccountKey, Token, Url, Data, Hs, Attempt+1);
	{ok,Resp,_Body} when Resp#http_response.status =:= 401 ->
	    case refresh(AccountKey) of
		{ok,Token1} ->
		    %% timer:sleep(2000),  %% wait a while...
		    %% cache_close(Url),
		    wpost_(AccountKey, Token1, Url, Data, Hs, Attempt+1);
		Error ->
		    Error
	    end;
	{ok,Resp,Body} ->
	    %% B = jsone:decode(Body),
	    {error,Resp#http_response.status,Body};
	Error ->
	    Error
    end;
wpost_(_AccountKey, _Token, _Url, _Data, _Hs, _Attempt) ->
    {error, too_many_attempts}.



%% Get request with refresh/login if needed
wdelete(AccountKey, Path) -> wdelete(AccountKey, Path, []).
wdelete(AccountKey, Path, Hs) ->
    {ok,{ApiUrl,Token}} = token(AccountKey),
    wdelete_(AccountKey, Token, ApiUrl ++ Path, Hs, 1).
    
wdelete_(AccountKey, Token, Url, Hs, Attempt) when Attempt < 3 ->
    Req = rester_http:make_request('DELETE',Url,{1,1},
				   [{'Authorization', ["Bearer ", Token]},
				    {'Accept',"application/json"} | Hs]),
    case rester_http:request(Req,[],5000) of
	{ok,Resp,Body} when Resp#http_response.status =:= 200 ->
	    {ok,jsone:decode(Body)};
	{error, closed} -> %% may happend when retreive stale socket from cache
	    %% does this count as an attempt? fixme...
	    wdelete_(AccountKey, Token, Url, Hs, Attempt+1);
	{ok,Resp,_Body} when Resp#http_response.status =:= 401 ->
	    case refresh(AccountKey) of
		{ok,Token1} ->
		    %% timer:sleep(2000),  %% wait a while...
		    %% cache_close(Url),
		    wdelete_(AccountKey, Token1, Url, Hs, Attempt+1);
		Error ->
		    Error
	    end;
	{ok,Resp,Body} ->
	    %% B = jsone:decode(Body),
	    {error,Resp#http_response.status,Body};
	Error ->
	    Error
    end;
wdelete_(_AccountKey, _Token, _Url, _Hs, _Attempt) ->
    {error, too_many_attempts}.

%% Open a cached url and close it (remove from cache)
%% WORK around if needed
cache_close(Url0) ->    
    Req = rester_http:make_request('GET',Url0,{1,1},[]),
    URI = Req#http_request.uri,
    Url = if is_record(URI, url) -> URI;
	     is_list(URI) -> rester_url:parse(URI, sloppy)
	  end,
    Scheme = if Url#url.scheme =:= undefined -> http;
		true -> Url#url.scheme
	     end,
    Port = if Url#url.port =:= undefined ->
		   case Scheme of
		       http -> 80;
		       https -> 443;
		       ftp -> 21
		   end;
	      true -> Url#url.port
	   end,
    Proto = case Scheme of
		https -> [tcp,ssl,http];
		_ -> [tcp,http]
	    end,
    case rester_socket_cache:open(Proto,
				  Req#http_request.version,
				  Url#url.host,
				  Port, 1000) of
	{ok, S} ->
	    rester_socket:close(S);
	Error ->
	    io:format("socket cache error: ~p\n", [Error])
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

seconds_since_mod(Filename) ->
    case read_file_info(Filename) of
	{error, enoent} -> never;
	{ok, FI} -> time_diff({date(),time()}, FI#file_info.mtime)
    end.

file_mod(Filename) ->
    case read_file_info(Filename) of
	{error, enoent} -> never;
	{ok, FI} -> FI#file_info.mtime
    end.
    
to_string(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
to_string(IOList) ->
    try binary_to_list(iolist_to_binary(IOList)) of
	List -> List
    catch
	error:_ -> false
    end.

to_binary(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom);
to_binary(IOList) ->
    try iolist_to_binary(IOList) of
	List -> List
    catch
	error:_ -> false
    end.

read_password(Account) ->
    if Account#account.password =:= file;
       Account#account.password =:= undefined ->
	    read_file(Account#account.password_filename);
       true ->
	    {ok,Account#account.password}
    end.

read_apikey(Account) ->
    if Account#account.api_key =:= file;
       Account#account.api_key =:= undefined ->
	    read_file(Account#account.api_key_filename);
       true ->
	    {ok,Account#account.api_key}
    end.

read_file_info(Filename) ->
    XFilename = expand_filename(Filename),    
    io:format("Read file info: ~p\n", [XFilename]),
    file:read_file_info(XFilename).

read_file(Filename) ->
    XFilename = expand_filename(Filename),
    io:format("Read file: ~p\n", [XFilename]),
    case file:read_file(XFilename) of
	{ok,Bin} -> {ok,string:trim(Bin)};
	Error -> Error
    end.

write_file(undefined, _Data) -> %% ignore file not configured
    ok;
write_file(Filename, Data) ->
    XFilename = expand_filename(Filename),
    io:format("Write file: ~p\n", [XFilename]),
    io:format("      data: ~p\n", [Data]),
    Dir = filename:dirname(XFilename),
    filelib:ensure_path(Dir),
    file:write_file(XFilename, Data).

expand_filename(Filename) ->
    [Fst|Vs] = binary:split(iolist_to_binary(Filename),<<"${">>,[global]),
    iolist_to_binary([Fst | env_vars(Vs)]).

env_vars([V | Vs]) ->
    case binary:split(V, <<"}">>) of
	[Var,Tail] ->
	    [os:getenv(binary_to_list(Var)),Tail | env_vars(Vs)];
	[Tail] ->
	    [Tail | env_vars(Vs)]
    end;
env_vars([]) ->
    [].


time_diff(DT1, DT0) ->
    calendar:datetime_to_gregorian_seconds(DT1) -
	calendar:datetime_to_gregorian_seconds(DT0).
