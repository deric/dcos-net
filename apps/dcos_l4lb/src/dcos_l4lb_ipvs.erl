%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 18. Oct 2016 12:48 AM
%%%-------------------------------------------------------------------
-module(dcos_l4lb_ipvs).
-author("sdhillon").

-behaviour(gen_statem).

%% REMOVE me
-compile(export_all).

-include_lib("gen_netlink/include/netlink.hrl").
-define(SERVER, ?MODULE).

-record(state, {
    last_configured,
    netlink_generic :: pid(),
    netlink_rt      :: pid(),
    family,
    if_idx
}).

-type state_data() :: #state{}.

-type state_name() :: uninitialized | initialized.

-define(IP_VS_CONN_F_FWD_MASK, 16#7).       %%  mask for the fwd methods
-define(IP_VS_CONN_F_MASQ, 16#0).           %%  masquerading/NAT
-define(IP_VS_CONN_F_LOCALNODE, 16#1).      %%  local node
-define(IP_VS_CONN_F_TUNNEL, 16#2).         %%  tunneling
-define(IP_VS_CONN_F_DROUTE, 16#3).         %%  direct routing
-define(IP_VS_CONN_F_BYPASS, 16#4).         %%  cache bypass
-define(IP_VS_CONN_F_SYNC, 16#20).          %%  entry created by sync
-define(IP_VS_CONN_F_HASHED, 16#40).        %%  hashed entry
-define(IP_VS_CONN_F_NOOUTPUT, 16#80).      %%  no output packets
-define(IP_VS_CONN_F_INACTIVE, 16#100).     %%  not established
-define(IP_VS_CONN_F_OUT_SEQ, 16#200).      %%  must do output seq adjust
-define(IP_VS_CONN_F_IN_SEQ, 16#400).       %%  must do input seq adjust
-define(IP_VS_CONN_F_SEQ_MASK, 16#600).     %%  in/out sequence mask
-define(IP_VS_CONN_F_NO_CPORT, 16#800).     %%  no client port set yet
-define(IP_VS_CONN_F_TEMPLATE, 16#1000).    %%  template, not connection
-define(IP_VS_CONN_F_ONE_PACKET, 16#2000).  %%  forward only one packet

-define(IP_VS_SVC_F_PERSISTENT, 16#1).          %% persistent port */
-define(IP_VS_SVC_F_HASHED,     16#2).          %% hashed entry */
-define(IP_VS_SVC_F_ONEPACKET,  16#4).          %% one-packet scheduling */
-define(IP_VS_SVC_F_SCHED1,     16#8).          %% scheduler flag 1 */
-define(IP_VS_SVC_F_SCHED2,     16#10).          %% scheduler flag 2 */
-define(IP_VS_SVC_F_SCHED3,     16#20).          %% scheduler flag 3 */

-define(MINUTEMAN_IFACE, "minuteman").
%% API
-export([start_link/0]).
-export([push_vips/1]).


%% gen_statem behaviour
-export([init/1, terminate/3, code_change/4, callback_mode/0, handle_event/4]).

%% State callbacks
-export([]).

push_vips(VIPs) ->
    gen_statem:cast(?SERVER, {vips, VIPs}).

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(init([]) -> {ok, state_name(), state_data()}).
init([]) ->
    {ok, Pid} = dcos_l4lb_netlink:start_link(),
    {ok, Family} = dcos_l4lb_netlink:get_family(Pid, "IPVS"),
    {ok, PidRT} = dcos_l4lb_netlink:start_link(?NETLINK_ROUTE),
    State0 = #state{family = Family, netlink_generic = Pid, netlink_rt = PidRT},
    IfIdx = if_idx(?MINUTEMAN_IFACE, State0),
    State1 = State0#state{if_idx = IfIdx},
    {ok, uninitialized, State1}.

terminate(Reason, State, Data) ->
    lager:warning("Terminating, due to: ~p, in state: ~p, with state data: ~p", [Reason, State, Data]).

code_change(_OldVsn, OldState, OldData, _Extra) ->
    {ok, OldState, OldData}.

callback_mode() ->
    handle_event_function.

%% TODO: We need to do lashup integration and make it so there are availability checks


%handle_event(EventType, EventContent, StateName, #state{}) ->
%% In the uninitialized state, we want to enumerate the VIPs that exist,
%% and we want to delete the VIPs that aren't in the list
%% Then we we redeliver the event for further processing
%% VIPs are in the structure [{{protocol(), inet:ipv4_address(), port_num}, [{inet:ipv4_address(), port_num}]}]
%% [{{tcp,{1,2,3,4},80},[{{33,33,33,2},20320}]}]
handle_event(cast, {vips, VIPsUnsorted}, uninitialized, State0 = #state{}) ->
    VIPs = sort_vips(VIPsUnsorted),
    reconcile_vips(VIPs, State0),
    reconcile_interfaces(VIPs, State0),
    reconcile_backends(VIPs, State0),
    State1 = State0#state{last_configured = VIPs},
    {next_state, initialized, State1};
handle_event(cast, {vips, VIPsNewUnsorted}, initialized, State = #state{last_configured = VIPsOld}) ->
    VIPsNew = sort_vips(VIPsNewUnsorted),
    transition_vips_and_interfaces(VIPsOld, VIPsNew, State),
    {next_state, initialized, State};
handle_event(EventType, EventContent, StateName, StateData) ->
    lager:info("~p; ~p; ~p; ~p", [EventType, EventContent, StateName, StateData]),
    keep_state_and_data.

sort_vips(VIPs0) ->
    VIPs1 = orddict:from_list(VIPs0),
    orddict:map(fun(_Key, Backends) -> ordsets:from_list(Backends) end, VIPs1).

installed_services(#state{family = Family, netlink_generic = Pid}) ->
    AF = netlink_codec:family_to_int(inet),
    Protocol = netlink_codec:protocol_to_int(tcp),
    Message =
        #get_service{request = [
            {service, [
                {address_family, AF},
                {protocol, Protocol}
            ]}
        ]},
    {ok, Replies} = dcos_l4lb_netlink:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(service, MaybeService) || #netlink{msg = #new_service{request = MaybeService}} <- Replies,
        proplists:is_defined(service, MaybeService)].

reconcile_backends(VIPsAndBackends, State) ->
    InstalledServices = installed_services(State),
    Reconcilable = services_to_reconcile(InstalledServices, VIPsAndBackends),
    lists:foreach(fun(RS) -> reconcile_service(RS, State) end, Reconcilable).

services_to_reconcile(InstalledServices, VIPsAndBackends) ->
    lists:filtermap(
        fun(Service) ->
            case lists:keyfind(service_address(Service), 1, VIPsAndBackends) of
                false -> false;
                VIPAndBackends -> {true, {Service, VIPAndBackends}}
            end
        end,
        InstalledServices).

reconcile_service({Service, {_VIP, Backends}}, State) ->
    lager:info("Reconciling service: ~p", [Service]),
    InstalledBackends = installed_backends(Service, State),
    BackendsToAdd = backends_to_add(InstalledBackends, Backends),
    lists:foreach(fun(BE) -> add_backend_to_service(BE, Service, State) end, BackendsToAdd),
    BackendsToDelete = backends_to_delete(InstalledBackends, Backends),
    lists:foreach(fun(BE) -> delete_backend(BE, Service, State) end, BackendsToDelete).

backends_to_add(InstalledBackends, Backends0) ->
    NormalizedInstalledBackends0 = lists:map(fun backend_address/1, InstalledBackends),
    Backends1 = ordsets:from_list(Backends0),
    NormalizedInstalledBackends1 = ordsets:from_list(NormalizedInstalledBackends0),
    ordsets:subtract(Backends1, NormalizedInstalledBackends1).

backends_to_delete(InstalledBackends, Backends) ->
    lists:filter(
        fun(InstalledBackend) ->
            not lists:member(backend_address(InstalledBackend), Backends)
        end,
        InstalledBackends
    ).

installed_backends(Service, #state{family = Family, netlink_generic = Pid}) ->
    Message = #get_dest{request = [{service, Service}]},
    {ok, Replies} = dcos_l4lb_netlink:request(Pid, Family, ipvs, [root, match], Message),
    [proplists:get_value(dest, MaybeDest) || #netlink{msg = #new_dest{request = MaybeDest}} <- Replies,
        proplists:is_defined(dest, MaybeDest)].

reconcile_interfaces(VIPsAndBackends, State) ->
    VIPs = [VIP || {VIP, _Backends} <- VIPsAndBackends],
    VIPIPs = [IP || {_Protocol, IP, _Port} <- VIPs],
    IfaceAddrs = dcos_l4lb_iface_addrs(),
    IPsToAdd = ips_to_add(IfaceAddrs, VIPIPs),
    IPsToDel = ips_to_del(IfaceAddrs, VIPIPs),
    lists:foreach(fun(IP) -> add_ip(IP, State) end, IPsToAdd),
    lists:foreach(fun(IP) -> del_ip(IP, State) end, IPsToDel).

if_idx(InterfaceName, #state{netlink_rt = Pid}) ->
    Msg = if_idx_msg(InterfaceName),
    {ok, [#rtnetlink{msg = Reply}]} = dcos_l4lb_netlink:rtnl_request(Pid, getlink, [], Msg),
    {_Family, _Type, Index, _Flags, _Change, _Req} = Reply,
    Index.

if_idx_msg(InterfaceName) ->
    {
        _Family = packet,
        _Type = arphrd_ether,
        _Index = 0,
        _Flags = [],
        _Change = [],
        _Req = [
            {ifname, InterfaceName},
            {ext_mask, 1}
        ]
    }.

ips_to_add(IfaceAddrs, VIPIPs) ->
    ordsets:subtract(ordsets:from_list(VIPIPs), ordsets:from_list(IfaceAddrs)).

ips_to_del(IfaceAddrs, VIPIPs) ->
    ordsets:subtract(ordsets:from_list(IfaceAddrs), ordsets:from_list(VIPIPs)).

add_ip(IP, #state{netlink_rt = Pid, if_idx = Index}) ->
    Req = [{address, IP}, {local, IP}],
    Msg =  {_Family = inet, _PrefixLen = 32, _Flags = 0, _Scope = 0, Index, Req},
    {ok, _} = dcos_l4lb_netlink:rtnl_request(Pid, newaddr, [create], Msg).

del_ip(IP, #state{netlink_rt = Pid, if_idx = Index}) ->
    Req = [{address, IP}, {local, IP}],
    Msg =  {_Family = inet, _PrefixLen = 32, _Flags = 0, _Scope = 0, Index, Req},
    {ok, _} = dcos_l4lb_netlink:rtnl_request(Pid, deladdr, [], Msg).


dcos_l4lb_iface_addrs() ->
    {ok, IFaceAddrs} = inet:getifaddrs(),
    dcos_l4lb_iface_addrs(IFaceAddrs).

dcos_l4lb_iface_addrs(IFaceAddrs) ->
    [IFaceOpts] = [IfaceOpts || {?MINUTEMAN_IFACE, IfaceOpts} <- IFaceAddrs],
    [Addr || {addr, Addr} <- IFaceOpts, size(Addr) == 4].

%% TODO: Add IPs to minuteman interface
reconcile_vips(VIPsAndBackends, State) ->
    VIPs = [VIP || {VIP, _Backends} <- VIPsAndBackends],
    InstalledServices = installed_services(State),
    MaybeRemovableServices = lists:filter(filter_fun(), InstalledServices),
    RemovableServices = services_to_delete(MaybeRemovableServices, VIPs),
    lists:foreach(fun(Svc) -> delete_service(Svc, State) end, RemovableServices),
    AddableVIPs = vips_to_add(InstalledServices, VIPs),
    lists:foreach(fun(VIP) -> add_vip(VIP, State) end, AddableVIPs).


services_to_delete(InstalledServices, VIPs) ->
    lists:filter(fun(Service) -> not lists:member(service_address(Service), VIPs) end, InstalledServices).

%% TODO: Delete IP from Minuteman interface *first*
delete_service(Service, #state{family = Family, netlink_generic = Pid}) ->
    lager:info("Deleting service: ~p~n", [Service]),
    {ok, _} = dcos_l4lb_netlink:request(Pid, Family, ipvs, [], #del_service{request = [{service, Service}]}).

vips_to_add(InstalledServices0, VIPs) ->
    lager:debug("Service: ~p", [InstalledServices0]),
    InstalledServices1 = lists:map(fun service_address/1, InstalledServices0),
    ordsets:subtract(ordsets:from_list(VIPs), ordsets:from_list(InstalledServices1)).

%% TODO: Add IP to minuteman interface *after*
% 14:23:19.251 [dcos_l4lb_ipvs:177]  [debug] Service: [[{address_family,2},{protocol,6},{address,<<7,7,7,7,0,0,0,0,0,0,0,0,0,0,0,0>>},{port,6666},{sched_name,"wlc"},{flags,2,4294967295},{timeout,0},{netmask,4294967295},{stats,[{conns,22},{inpkts,73},{outpkts,3},{inbytes,4351},{outbytes,164},{cps,0},{inpps,0},{outpps,0},{inbps,0},{outbps,0}]},{stats64,[{conns,22},{inpkts,73},{outpkts,3},{inbytes,4351},{outbytes,164},{cps,0},{inpps,0},{outpps,0},{inbps,0},{outbps,0}]}],[{address_family,2},{protocol,6},{address,<<7,7,7,7,0,0,0,0,0,0,0,0,0,0,0,0>>},{port,80},{sched_name,"wlc"},{flags,2,4294967295},{timeout,0},{netmask,4294967295},{stats,[{conns,1},{inpkts,5},{outpkts,0},{inbytes,300},{outbytes,0},{cps,0},{inpps,0},{outpps,0},{inbps,0},{outbps,0}]},{stats64,[{conns,1},{inpkts,5},{outpkts,0},{inbytes,300},{outbytes,0},{cps,0},{inpps,0},{outpps,0},{inbps,0},{outbps,0}]}]]


add_vip({tcp, IP, Port}, #state{family = Family, netlink_generic = Pid}) ->
    Flags = 0,
    Service0 = [{protocol, netlink_codec:protocol_to_int(tcp)}, {port, Port}, {sched_name, "wlc"}, {netmask, 16#ffffffff}, {flags, Flags, 16#ffffffff}, {timeout, 0}],
    Service1 = ip_to_address(IP) ++ Service0,
    lager:info("Adding Service: ~p", [Service1]),
    {ok, _} = dcos_l4lb_netlink:request(Pid, Family, ipvs, [], #new_service{request = [{service, Service1}]}).

%02:37:43.920 [dcos_l4lb_ipvs:158]  [info] Deleting Backend: [{address,<<216,58,194,174,0,0,0,0,0,0,0,0,0,0,0,0>>},{port,80},{fwd_method,0},{weight,1},{u_threshold,0},{l_threshold,0},{active_conns,0},{inact_conns,0},{persist_conns,0},{addr_family,2},{stats,[{conns,1},{inpkts,6},{outpkts,5},{inbytes,331},{outbytes,744},{cps,0},{inpps,0},{outpps,0},{inbps,0},{outbps,0}]},{stats64,[{conns,1},{inpkts,6},{outpkts,5},{inbytes,331},{outbytes,744},{cps,0},{inpps,0},{outpps,0},{inbps,0},{outbps,0}]}]
add_backend_to_service(BE = {IP, Port}, Service, #state{family = Family, netlink_generic = Pid}) ->
    Base = [{fwd_method, ?IP_VS_CONN_F_MASQ}, {weight, 1}, {u_threshold, 0}, {l_threshold, 0}],
    Dest = [{port, Port}] ++ Base ++ ip_to_address(IP),
    lager:info("Adding backend ~p to service ~p~n", [BE, Service]),
    Msg = #new_dest{request = [{dest, Dest}, {service, Service}]},
    {ok, _} = dcos_l4lb_netlink:request(Pid, Family, ipvs, [], Msg).

delete_backend(Backend, Service, #state{family = Family, netlink_generic = Pid}) ->
    lager:info("Deleting Backend: ~p~n", [Backend]),
    Msg = #del_dest{request = [{dest, Backend}, {service, Service}]},
    {ok, _} = dcos_l4lb_netlink:request(Pid, Family, ipvs, [], Msg).

%% @doc returns a function to filter services that fall into the named VIP range
filter_fun() ->
    MinNamedIP = dcos_l4lb_config:min_named_ip(),
    MaxNamedIP = dcos_l4lb_config:max_named_ip(),
    fun(Service) ->
        {_Protocol, Address, _Port} = service_address(Service),
        in_range(Address, MinNamedIP, MaxNamedIP)
    end.

transition_vips_and_interfaces(VIPsOld, VIPsNew, State) ->
    delete_old_vips_and_interfaces(VIPsOld, VIPsNew, State),
    create_new_vips_and_interfaces(VIPsOld, VIPsNew, State),
    transition_services(VIPsOld, VIPsNew, State).

transition_services(VIPsOld, VIPsNew, State) ->
    InstalledServices = installed_services(State),
    lists:foreach(fun(Service) -> transition_service(Service, VIPsOld, VIPsNew, State) end, InstalledServices).

find_or_default(Key, Orddict, Default) ->
    case orddict:find(Key, Orddict) of
        error ->
            Default;
        {ok, Value} ->
            Value
    end.
transition_service(Service, VIPsOld, VIPsNew, State) ->
    Key = service_address(Service),
    OldBackends = find_or_default(Key, VIPsOld, []),
    NewBackends = orddict:fetch(Key, VIPsNew),
    update_backends(Service, OldBackends, NewBackends, State).

update_backends(Service, OldBackends, NewBackends, State) ->
    BackendsToDelete = ordsets:subtract(OldBackends, NewBackends),
    BackendsToAdd = ordsets:subtract(NewBackends, OldBackends),
    lists:foreach(fun(BE) -> add_backend_to_service(BE, Service, State) end, BackendsToAdd),
    lists:foreach(fun(BE) -> delete_backend(BE, Service, State) end, BackendsToDelete).

delete_old_vips_and_interfaces(VIPsOld, VIPsNew, State) ->
    InstalledServices = installed_services(State),
    VIPsToDelete = ordsets:subtract(orddict:fetch_keys(VIPsOld), orddict:fetch_keys(VIPsNew)),
    ServicesToDelete = lists:filter(fun(Service) -> lists:member(service_address(Service), VIPsToDelete) end, InstalledServices),
    lists:foreach(fun(Service) -> delete_service(Service, State) end, ServicesToDelete),
    IPsToDelete = [IP || {_Protocol, IP, _Port} <- VIPsToDelete],
    lists:foreach(fun(IP) -> del_ip(IP, State) end, IPsToDelete).

create_new_vips_and_interfaces(VIPsOld, VIPsNew, State) ->
    VIPsToAdd = ordsets:subtract(orddict:fetch_keys(VIPsNew), orddict:fetch_keys(VIPsOld)),
    lists:foreach(fun(VIP) -> add_vip(VIP, State) end, VIPsToAdd),
    IPsToAdd = [IP || {_Protocol, IP, _Port} <- VIPsToAdd],
    lists:foreach(fun(IP) -> add_ip(IP, State) end, IPsToAdd).


-spec(in_range(inet:ip4_address(), inet:ip4_address(), inet:ip4_address()) -> boolean()).
in_range(Address, Min, Max) when Address >= Min andalso Address =< Max ->
    true;
in_range(_Address, _Min, _Max) ->
    false.

ip_to_address(IP0) when size(IP0) == 4 ->
    [{address_family, netlink_codec:family_to_int(inet)}, {address, ip_to_address2(IP0)}];
ip_to_address(IP0) when size(IP0) == 16 ->
    [{address_family, netlink_codec:family_to_int(inet6)}, {address, ip_to_address2(IP0)}].

ip_to_address2(IP0) ->
    IP1 = tuple_to_list(IP0),
    IP2 = binary:list_to_bin(IP1),
    Padding = 8 * (16 - size(IP2)),
    <<IP2/binary, 0:Padding/integer>>.

-spec(service_address(Service :: list()) -> {protocol(), inet:ip4_address(), inet:port_number()}).
service_address(Service) ->
    AF = proplists:get_value(address_family, Service),
    Protocol = netlink_codec:protocol_to_atom(proplists:get_value(protocol, Service)),
    AddressBin = proplists:get_value(address, Service),
    AddressList = binary:bin_to_list(AddressBin),
    Port = proplists:get_value(port, Service),
    case netlink_codec:family_to_atom(AF) of
        inet ->
            InetAddr = list_to_tuple(lists:sublist(AddressList, 4)),
            {Protocol, InetAddr, Port}
    end.

-spec(backend_address(Service :: list()) -> {inet:ip4_address(), inet:port_number()}).
backend_address(Service) ->
    AF = proplists:get_value(address_family, Service),
    AddressBin = proplists:get_value(address, Service),
    AddressList = binary:bin_to_list(AddressBin),
    Port = proplists:get_value(port, Service),
    case netlink_codec:family_to_atom(AF) of
        inet ->
            InetAddr = list_to_tuple(lists:sublist(AddressList, 4)),
            {InetAddr, Port}
    end.