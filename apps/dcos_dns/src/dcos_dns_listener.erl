-module(dcos_dns_listener).
-behaviour(gen_server).

-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_continue/2,
    handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-record(state, {
    ref = erlang:error() :: reference()
}).

-include("dcos_dns.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("dns/include/dns.hrl").


-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, {}, {continue, {}}}.

handle_continue({}, {}) ->
    MatchSpec =
        case dcos_dns_config:store_modes() of
            [lww | _Modes] ->
                ets:fun2ms(fun ({?LASHUP_LWW_KEY('_')}) -> true end);
            [set | _Modes] ->
                ets:fun2ms(fun ({?LASHUP_SET_KEY('_')}) -> true end)
        end,
    {ok, Ref} = lashup_kv_events_helper:start_link(MatchSpec),
    {noreply, #state{ref = Ref}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({lashup_kv_events, Event = #{ref := Ref, key := Key}},
        State0 = #state{ref = Ref}) ->
    Event0 = skip_kv_event(Event, Ref, Key),
    State1 = handle_event(Event0, State0),
    {noreply, State1};
handle_info(_Info, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(skip_kv_event(Event, reference(), term()) -> Event when Event :: map()).
skip_kv_event(Event, Ref, Key) ->
    % Skip current lashup kv event if there is yet another event in
    % the message queue. It should improve the convergence.
    receive
        {lashup_kv_events, #{ref := Ref, key := Key} = Event0} ->
            skip_kv_event(Event0, Ref, Key)
    after 0 ->
        Event
    end.

handle_event(#{key := ?LASHUP_SET_KEY(ZoneName), value := Value}, State) ->
    {?RECORDS_SET_FIELD, Records} = lists:keyfind(?RECORDS_SET_FIELD, 1, Value),
    ok = push_zone(ZoneName, Records),
    State;
handle_event(#{key := ?LASHUP_LWW_KEY(ZoneName), value := Value}, State) ->
    {?RECORDS_LWW_FIELD, Records} = lists:keyfind(?RECORDS_LWW_FIELD, 1, Value),
    ok = push_zone(ZoneName, Records),
    State.

push_zone(ZoneName, Records) ->
    ok = dcos_dns:push_prepared_zone(ZoneName, Records),
    case dcos_dns_key_mgr:keys() of
        false -> ok;
        #{public_key := PublicKey} ->
            {SignedZoneName, SignedRecords} = convert_zone(PublicKey, ZoneName, Records),
            ok = dcos_dns:push_prepared_zone(SignedZoneName, SignedRecords)
    end.

%%%===================================================================
%%% Convert functions
%%%===================================================================

convert_zone(PublicKey, ZoneName0, Records0) ->
    PublicKeyEncoded = zbase32:encode(PublicKey),
    NewPostfix = <<".", PublicKeyEncoded/binary, ".dcos.directory">>,
    convert_zone(ZoneName0, Records0, ?DCOS_DIRECTORY(""), NewPostfix).

%% For our usage postfix -> thisdcos.directory
%% New Postfix is $(zbase32(public_key).thisdcos.directory)
convert_zone(ZoneName0, Records0, Postfix, NewPostfix) ->
    ZoneName1 = convert_name(ZoneName0, Postfix, NewPostfix),
    Records1 = lists:filtermap(fun(Record) -> convert_record(Record, Postfix, NewPostfix) end, Records0),
    {ZoneName1, Records1}.

convert_name(Name, Postfix, NewPostfix) ->
    Size = size(Name) - size(Postfix),
    <<FrontName:Size/binary, Postfix/binary>> = Name,
    <<FrontName/binary, NewPostfix/binary>>.

convert_record(Record0 = #dns_rr{type = ?DNS_TYPE_A, name = Name0}, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Record1 = Record0#dns_rr{name = Name1},
    {true, Record1};
convert_record(#dns_rr{
            type = ?DNS_TYPE_SRV, name = Name0,
            data = Data0 = #dns_rrdata_srv{target = Target0}
        } = Record0, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Target1 = convert_name(Target0, Postfix, NewPostfix),
    Data1 = Data0#dns_rrdata_srv{target = Target1},
    Record1 = Record0#dns_rr{name = Name1, data = Data1},
    {true, Record1};
convert_record(Record0 = #dns_rr{name = Name0}, Postfix, NewPostfix) ->
    Name1 = convert_name(Name0, Postfix, NewPostfix),
    Record1 = Record0#dns_rr{name = Name1},
    {true, Record1}.

%%%===================================================================
%%% Test functions
%%%===================================================================

-ifdef(TEST).
zone_convert_test() ->

    Records = [{dns_rr, <<"_framework._tcp.marathon.mesos.thisdcos.directory">>, 1,
        33, 5,
        {dns_rrdata_srv, 0, 0, 36241,
            <<"marathon.mesos.thisdcos.directory">>}},
        {dns_rr, <<"_leader._tcp.mesos.thisdcos.directory">>, 1, 33, 5,
            {dns_rrdata_srv, 0, 0, 5050,
                <<"leader.mesos.thisdcos.directory">>}},
        {dns_rr, <<"_leader._udp.mesos.thisdcos.directory">>, 1, 33, 5,
            {dns_rrdata_srv, 0, 0, 5050,
                <<"leader.mesos.thisdcos.directory">>}},
        {dns_rr, <<"_slave._tcp.mesos.thisdcos.directory">>, 1, 33, 5,
            {dns_rrdata_srv, 0, 0, 5051,
                <<"slave.mesos.thisdcos.directory">>}},
        {dns_rr, <<"leader.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"marathon.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"master.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"master0.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"mesos.thisdcos.directory">>, 1, 2, 3600,
            {dns_rrdata_ns, <<"ns.spartan">>}},
        {dns_rr, <<"mesos.thisdcos.directory">>, 1, 6, 3600,
            {dns_rrdata_soa, <<"ns.spartan">>,
                <<"support.mesosphere.com">>, 1, 60, 180, 86400,
                1}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 6, 47}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {172, 17, 0, 1}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {198, 51, 100, 1}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {198, 51, 100, 2}}},
        {dns_rr, <<"root.ns1.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {198, 51, 100, 3}}},
        {dns_rr, <<"slave.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 3, 101}}},
        {dns_rr, <<"slave.mesos.thisdcos.directory">>, 1, 1, 5,
            {dns_rrdata_a, {10, 0, 5, 155}}}],
    PublicKey = <<86, 39, 137, 9, 82, 47, 191, 138, 216, 134, 104, 152, 135, 11, 173, 38, 150, 107, 238, 7, 78,
        78, 17, 127, 194, 164, 28, 239, 31, 178, 219, 57>>,
    _SecretKey = <<243, 180, 170, 246, 243, 250, 151, 209, 107, 185, 80, 245, 39, 121, 7, 61, 151, 249, 79, 98,
        212, 191, 61, 252, 40, 107, 219, 230, 21, 215, 108, 98, 86, 39, 137, 9, 82, 47, 191, 138, 216,
        134, 104, 152, 135, 11, 173, 38, 150, 107, 238, 7, 78, 78, 17, 127, 194, 164, 28, 239, 31,
        178, 219, 57>>,
    PublicKeyEncoded = zbase32:encode(PublicKey),
    Postfix = <<"thisdcos.directory">>,
    NewPostfixA = <<PublicKeyEncoded/binary, <<".dcos.directory">>/binary>>,
    %NewPostfixA = <<PublicKeyEncoded/binary, <<".dcos.directory">>>>
    {NewName, NewRecords} = convert_zone(<<"mesos.thisdcos.directory">>, Records, Postfix, NewPostfixA),
    ExpectedName = <<"mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
    ?assertEqual(ExpectedName, NewName),
    ExpectedRecords =
        [
            {dns_rr,
            <<"_framework._tcp.marathon.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
            1, 33, 5,
            {dns_rrdata_srv, 0, 0, 36241,
                <<"marathon.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"_leader._tcp.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 33, 5,
                {dns_rrdata_srv, 0, 0, 5050,
                    <<"leader.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"_leader._udp.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 33, 5,
                {dns_rrdata_srv, 0, 0, 5050,
                    <<"leader.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"_slave._tcp.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 33, 5,
                {dns_rrdata_srv, 0, 0, 5051,
                    <<"slave.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>}},
            {dns_rr, <<"leader.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"marathon.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"master.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"master0.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>, 1, 2, 3600,
                {dns_rrdata_ns, <<"ns.spartan">>}},
            {dns_rr, <<"mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>, 1, 6, 3600,
                {dns_rrdata_soa, <<"ns.spartan">>,
                    <<"support.mesosphere.com">>, 1, 60, 180, 86400,
                    1}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 6, 47}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {172, 17, 0, 1}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {198, 51, 100, 1}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {198, 51, 100, 2}}},
            {dns_rr, <<"root.ns1.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {198, 51, 100, 3}}},
            {dns_rr, <<"slave.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 3, 101}}},
            {dns_rr, <<"slave.mesos.kaualnklf69aisrgpnceqn7pr4mgz5o8j38bn96nwoqq687l5cho.dcos.directory">>,
                1, 1, 5,
                {dns_rrdata_a, {10, 0, 5, 155}}}],
    ?assertEqual(ExpectedRecords, NewRecords).
-endif.
