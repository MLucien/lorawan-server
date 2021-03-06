%
% Copyright (c) 2016-2017 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
% LoRaWAN 1.0.1 compliant MAC implementation
% Supports Class A devices
%
-module(lorawan_mac).

-export([process_frame/3, process_status/2]).
-export([handle_downlink/3, handle_multicast/3]).
-export([binary_to_hex/1, hex_to_binary/1]).
% for unit testing
-export([reverse/1, cipher/5, b0/4]).

-define(MAX_FCNT_GAP, 16384).
-define(MAX_LOST_AFTER_RESET, 10).

-include_lib("lorawan_server_api/include/lorawan_application.hrl").
-include("lorawan.hrl").

-record(frame, {devaddr, adr, adr_ack_req, ack, fcnt, fopts, fport, data}).

process_frame(MAC, RxQ, PHYPayload) ->
    Size = byte_size(PHYPayload)-4,
    <<Msg:Size/binary, MIC:4/binary>> = PHYPayload,
    case mnesia:dirty_read(gateways, MAC) of
        [] ->
            lager:warning("Unknown MAC ~s", [binary_to_hex(MAC)]),
            {error, {unknown_mac, MAC}};
        [Gateway] ->
            process_frame1(Gateway, RxQ, Msg, MIC)
    end.

process_status(MAC, S) ->
    case mnesia:dirty_read(gateways, MAC) of
        [] ->
            lager:warning("Unknown MAC ~s", [binary_to_hex(MAC)]),
            {error, {unknown_mac, MAC}};
        [G] ->
            mnesia:dirty_write(gateways,
                store_status(G#gateway{last_rx=calendar:universal_time()}, S)),
            ok
    end.

store_status(G, undefined) ->
    G;
store_status(G, S) ->
    store_pos(store_desc(G, S), S).

store_pos(G, S) ->
    if
        % store gateway GPS position
        is_number(S#stat.lati), is_number(S#stat.long), S#stat.lati /= 0, S#stat.long /= 0 ->
            if
                is_number(S#stat.alti), S#stat.alti /= 0 ->
                    G#gateway{ gpspos={S#stat.lati, S#stat.long}, gpsalt=S#stat.alti };
                true ->
                    % some cheap GPS receivers give proper coordinates, but a zero altitude
                    G#gateway{ gpspos={S#stat.lati, S#stat.long} }
            end;
        % position not received
        true ->
            G
    end.

store_desc(G, S) ->
    if
        is_binary(S#stat.desc), S#stat.desc /= <<>> ->
            G#gateway{ desc=S#stat.desc };
        true ->
            G
    end.

process_frame1(Gateway, RxQ, <<2#000:3, _:5,
        AppEUI0:8/binary, DevEUI0:8/binary, DevNonce:2/binary>> = Msg, MIC) ->
    {AppEUI, DevEUI} = {reverse(AppEUI0), reverse(DevEUI0)},

    case mnesia:dirty_read(devices, DevEUI) of
        [] ->
            lager:warning("Unknown DevEUI ~s", [binary_to_hex(DevEUI)]),
            {error, {unknown_deveui, DevEUI}};
        [D] when D#device.can_join == false ->
            lager:debug("Join ignored from DevEUI ~s", [binary_to_hex(DevEUI)]),
            ok;
        [D] ->
            case aes_cmac:aes_cmac(D#device.appkey, Msg, 4) of
                MIC ->
                    handle_join(Gateway, RxQ, AppEUI, DevEUI, DevNonce, D#device.appkey);
                _MIC2 ->
                    {error, {bad_mic, DevEUI}}
            end
    end;
process_frame1(Gateway, RxQ, <<MType:3, _:5,
        DevAddr0:4/binary, ADR:1, ADRACKReq:1, ACK:1, _RFU:1, FOptsLen:4,
        FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, Body/binary>> = Msg, MIC) ->
    {FPort, FRMPayload} = case Body of
        <<>> -> {undefined, <<>>};
        <<Port:8, Payload/binary>> -> {Port, Payload}
    end,
    DevAddr = reverse(DevAddr0),
    Frame = #frame{devaddr=DevAddr, adr=ADR, adr_ack_req=ADRACKReq, ack=ACK, fcnt=FCnt, fport=FPort},
    case check_link(DevAddr, FCnt) of
        {ok, Fresh, L} ->
            case aes_cmac:aes_cmac(L#link.nwkskey, <<(b0(MType band 1, DevAddr, L#link.fcntup, byte_size(Msg)))/binary, Msg/binary>>, 4) of
                MIC ->
                    case FPort of
                        0 when FOptsLen == 0 ->
                            Data = cipher(FRMPayload, L#link.nwkskey, MType band 1, DevAddr, L#link.fcntup),
                            handle_rxpk(Gateway, RxQ, MType, L, Fresh,
                                Frame#frame{fopts=reverse(Data), data= <<>>});
                        0 ->
                            {error, double_fopts};
                        _N ->
                            Data = cipher(FRMPayload, L#link.appskey, MType band 1, DevAddr, L#link.fcntup),
                            handle_rxpk(Gateway, RxQ, MType, L, Fresh,
                                Frame#frame{fopts=FOpts, data=reverse(Data)})
                    end;
                _MIC2 ->
                    {error, {bad_mic, DevAddr}}
            end;
        ignore ->
            ok;
        {error, Error} ->
            {error, Error}
    end;
process_frame1(_Gateway, _RxQ, Msg, _MIC) ->
    {error, {bad_frame, Msg}}.

handle_join(Gateway, RxQ, AppEUI, DevEUI, DevNonce, AppKey) ->
    AppNonce = crypto:strong_rand_bytes(3),
    NetID = Gateway#gateway.netid,
    NwkSKey = crypto:block_encrypt(aes_ecb, AppKey,
        padded(16, <<16#01, AppNonce/binary, NetID/binary, DevNonce/binary>>)),
    AppSKey = crypto:block_encrypt(aes_ecb, AppKey,
        padded(16, <<16#02, AppNonce/binary, NetID/binary, DevNonce/binary>>)),

    {atomic, Link} = mnesia:transaction(fun() ->
        [D] = mnesia:read(devices, DevEUI, write),
        NewAddr = if
            D#device.link == undefined;
            byte_size(D#device.link) < 4 ->
                create_devaddr(NetID);
            true ->
                D#device.link
        end,
        ok = mnesia:write(devices, D#device{link=NewAddr, last_join=calendar:universal_time()}, write),

        lager:info("JOIN REQUEST ~w ~w -> ~w",[AppEUI, DevEUI, NewAddr]),
        NewLink = #link{devaddr=NewAddr, region=D#device.region,
            app=D#device.app, appid=D#device.appid, appargs=D#device.appargs,
            nwkskey=NwkSKey, appskey=AppSKey, fcntup=0, fcntdown=0, fcnt_check=D#device.fcnt_check,
            last_mac=Gateway#gateway.mac, last_rxq=RxQ, adr_flag_use=0, adr_flag_set=D#device.adr_flag_set,
            adr_use=lorawan_mac_region:default_adr(D#device.region), adr_set=D#device.adr_set,
            rxwin_use=lorawan_mac_region:default_rxwin(D#device.region), rxwin_set=D#device.rxwin_set,
            last_reset=calendar:universal_time(), devstat_fcnt=undefined, last_qs=[]},
        ok = mnesia:write(links, NewLink, write),
        NewLink
    end),
    reset_link(Link#link.devaddr),
    case lorawan_handler:handle_join(Link#link.devaddr, Link#link.app, Link#link.appid, Link#link.appargs) of
        ok ->
            % transmitting after join accept delay 1
            TxQ = lorawan_mac_region:rx1_window(Link, RxQ, join1_delay),
            RxRate = lorawan_mac_region:rx2_dr(Link#link.region),
            txaccept(TxQ, RxRate, AppKey, AppNonce, NetID, Link#link.devaddr);
        {error, Error} -> {error, Error}
    end.

create_devaddr(NetID) ->
    <<_:17, NwkID:7>> = NetID,
    %% FIXME: verify uniqueness
    <<NwkID:7, 0:1, (crypto:strong_rand_bytes(3))/binary>>.

txaccept(TxQ, Rx2Rate, AppKey, AppNonce, NetID, DevAddr) ->
    MHDR = <<2#001:3, 0:3, 0:2>>,
    MACPayload = <<AppNonce/binary, NetID/binary, (reverse(DevAddr))/binary, 0:1, 0:3, Rx2Rate:4, 1>>,
    MIC = aes_cmac:aes_cmac(AppKey, <<MHDR/binary, MACPayload/binary>>, 4),

    % yes, decrypt; see LoRaWAN specification, Section 6.2.5
    PHYPayload = crypto:block_decrypt(aes_ecb, AppKey, padded(16, <<MACPayload/binary, MIC/binary>>)),
    {send, TxQ, <<MHDR/binary, PHYPayload/binary>>}.


check_link(DevAddr, FCnt) ->
    case is_ignored(DevAddr, mnesia:dirty_all_keys(ignored_links)) of
        true ->
            ignore;
        false ->
            check_link_fcnt(DevAddr, FCnt)
    end.

is_ignored(_DevAddr, []) ->
    false;
is_ignored(DevAddr, [Key|Rest]) ->
    [#ignored_link{devaddr=MatchAddr, mask=MatchMask}] = mnesia:dirty_read(ignored_links, Key),
    case match(DevAddr, MatchAddr, MatchMask) of
        true -> true;
        false -> is_ignored(DevAddr, Rest)
    end.

match(<<DevAddr:32>>, <<MatchAddr:32>>, undefined) ->
    DevAddr == MatchAddr;
match(<<DevAddr:32>>, <<MatchAddr:32>>, <<MatchMask:32>>) ->
    (DevAddr band MatchMask) == MatchAddr.

check_link_fcnt(DevAddr, FCnt) ->
    case mnesia:dirty_read(links, DevAddr) of
        [] ->
            lager:warning("Unknown DevAddr ~s", [binary_to_hex(DevAddr)]),
            {error, {unknown_devaddr, DevAddr}};
        [L] when (L#link.fcnt_check == 2 orelse L#link.fcnt_check == 3), FCnt < L#link.fcntup, FCnt < ?MAX_LOST_AFTER_RESET ->
            lager:debug("~w fcnt reset", [DevAddr]),
            % works for 16b only since we cannot distinguish between reset and 32b rollover
            {ok, reset, L#link{fcntup = FCnt, fcntdown=0,
                adr_use=lorawan_mac_region:default_adr(L#link.region),
                rxwin_use=lorawan_mac_region:default_rxwin(L#link.region),
                last_reset=calendar:universal_time(), devstat_fcnt=undefined, last_qs=[]}};
        [L] when L#link.fcnt_check == 3 ->
            % checks disabled
            {ok, new, L#link{fcntup = FCnt}};
        [L] when FCnt == L#link.fcntup ->
            % retransmission
            {ok, retransmit, L};
        [L] when L#link.fcnt_check == 1 ->
            % strict 32-bit
            case fcnt_gap32(L#link.fcntup, FCnt) of
                N when N < ?MAX_FCNT_GAP ->
                    % L#link.fcntup is 32b, but the received FCnt may be 16b only
                    LastFCnt = (L#link.fcntup + N) band 16#FFFFFFFF,
                    {ok, new, L#link{fcntup = LastFCnt}};
                _BigN ->
                    {error, {fcnt_gap_too_large, DevAddr, FCnt}}
            end;
        [L] ->
            % strict 16-bit (default)
            case fcnt_gap16(L#link.fcntup, FCnt) of
                N when N < ?MAX_FCNT_GAP ->
                    {ok, new, L#link{fcntup = FCnt}};
                _BigN ->
                    {error, {fcnt_gap_too_large, DevAddr, FCnt}}
            end
    end.

fcnt_gap16(A, B) ->
    if
        A =< B -> B - A;
        A > B -> 16#FFFF - A + B
    end.

fcnt_gap32(A, B) ->
    A16 = A band 16#FFFF,
    if
        A16 > B -> 16#10000 - A16 + B;
        true  -> B - A16
    end.

reset_link(DevAddr) ->
    ok = mnesia:dirty_delete(pending, DevAddr),
    % delete previously stored TX frames
    lorawan_db:purge_txframes(DevAddr).

build_rxframe(Gateway, Link, RxQ, Frame) ->
    TXPower = case Link#link.adr_use of
        {Power, _, _} -> Power;
        _Else -> undefined
    end,
    % #rxframe{frid, mac, rxq, average_qs, app, appid, region, devaddr, fcnt, port, data, datetime, devstat}
    #rxframe{frid= <<(erlang:system_time()):64>>,
        mac=Gateway#gateway.mac, powe=TXPower, rxq=RxQ, app=Link#link.app, appid=Link#link.appid,
        region=Link#link.region, devaddr=Link#link.devaddr,
        fcnt=Link#link.fcntup, port=Frame#frame.fport, data=Frame#frame.data,
        datetime=calendar:universal_time(), devstat=Link#link.devstat}.

handle_rxpk(Gateway, RxQ, MType, Link, Fresh, Frame)
        when MType == 2#010; MType == 2#100 ->
    <<Confirm:1, _:2>> = <<MType:3>>,
    case Fresh of
        new ->
            handle_uplink(Gateway, RxQ, Confirm, Link, Frame);
        reset ->
            reset_link(Link#link.devaddr),
            handle_uplink(Gateway, RxQ, Confirm, Link, Frame);
        retransmit ->
            % we want to see retransmissions too
            ok = mnesia:dirty_write(rxframes, build_rxframe(Gateway, Link, RxQ, Frame)),
            case retransmit_downlink(Link#link.devaddr) of
                {true, LostFrame} ->
                    TxQ = lorawan_mac_region:rx1_window(Link, RxQ, rx1_delay),
                    {send, TxQ, LostFrame};
                {false, _} ->
                    ok
            end
    end.

handle_uplink(Gateway, RxQ, Confirm, Link, #frame{devaddr=DevAddr, adr=ADR,
        adr_ack_req=ADRACKReq, ack=ACK, fcnt=FCnt, fport=FPort, fopts=FOpts, data=RxData}=Frame) ->
    % store parameters
    DataRate = lorawan_mac_region:datar_to_dr(Link#link.region, RxQ#rxq.datr),
    ULink =
        case Link#link.adr_use of
            {_TXPower, DataRate, _Chans} when Link#link.adr_flag_use == ADR ->
                % device didn't change any settings
                Link;
            {_TXPower, DataRate, _Chans} ->
                lager:debug("ADR indicator set to ~w", [ADR]),
                Link#link{adr_flag_use=ADR, devstat_fcnt=undefined, last_qs=[]};
            {TXPower, _OldDataRate, Chans} ->
                lager:debug("DataRate ~w switched to dr ~w", [Link#link.devaddr, DataRate]),
                Link#link{adr_flag_use=ADR, adr_use={TXPower, DataRate, Chans},
                    devstat_fcnt=undefined, last_qs=[]};
            undefined ->
                lager:debug("DataRate ~w switched to dr ~w", [Link#link.devaddr, DataRate]),
                Link#link{adr_flag_use=ADR, adr_use={undefined, DataRate, undefined},
                    devstat_fcnt=undefined, last_qs=[]}
        end,
    % process commands
    RxFrame = build_rxframe(Gateway, ULink, RxQ, Frame),
    {ok, L2, FOptsOut, RxFrame2} = lorawan_mac_commands:handle(RxQ, ULink, FOpts, RxFrame),
    ok = mnesia:dirty_write(links, L2#link{last_rx=calendar:universal_time(), last_mac=Gateway#gateway.mac, last_rxq=RxQ}),
    ok = mnesia:dirty_write(rxframes, RxFrame2),
    % check whether last downlink transmission was lost
    {LastLost, LostFrame} = repeat_downlink(DevAddr, ACK),
    % check whether the response is required
    ShallReply = if
        Confirm == 1 ->
            % confirmed uplink received
            true;
        ADRACKReq == 1 ->
            % ADR ACK was requested
            lager:debug("ADRACKReq confirmed"),
            true;
        byte_size(FOptsOut) > 0 ->
            % have MAC commands to send
            true;
        true ->
            % else
            false
    end,
    % invoke applications
    case lorawan_handler:handle_rx(Link#link.devaddr, Link#link.app, Link#link.appid, Link#link.appargs,
            #rxdata{fcnt=FCnt, port=FPort, data=RxData, last_lost=LastLost, shall_reply=ShallReply}, RxQ) of
        retransmit ->
            {send, choose_tx(Link, RxQ), LostFrame};
        {send, TxData} ->
            send_unicast(choose_tx(Link, RxQ), Link#link.devaddr, Confirm, FOptsOut, TxData);
        ok when ShallReply ->
            % application has nothing to send, but we still need to repond
            send_unicast(choose_tx(Link, RxQ), Link#link.devaddr, Confirm, FOptsOut, #txdata{});
        ok -> ok;
        {error, Error} -> {error, Error}
    end.

handle_downlink(Link, Time, TxData) ->
    TxQ = lorawan_mac_region:rx2_rf(Link, Link#link.last_rxq),
    % will ACK immediately, so server-initated Class C downlinks have ACK=0
    send_unicast(TxQ#txq{time=Time}, Link#link.devaddr, 0, lorawan_mac_commands:build_fopts(Link), TxData).

handle_multicast(Group, Time, TxData) ->
    TxQ = lorawan_mac_region:rf_group(Group),
    send_multicast(TxQ#txq{time=Time}, Group#multicast_group.devaddr, TxData).

choose_tx(Link, RxQ) ->
    Rx1Delay = lorawan_mac_region:regional_config(rx1_delay, Link#link.region) / 1000,
    {ok, GwDelay} = application:get_env(lorawan_server, preprocessing_delay),
    % transmit as soon as possible
    case erlang:monotonic_time(milli_seconds) - RxQ#rxq.srvtmst of
        Small when Small < Rx1Delay - GwDelay ->
            lorawan_mac_region:rx1_window(Link, RxQ, rx1_delay);
        _Big ->
            lorawan_mac_region:rx2_window(Link, RxQ, rx2_delay)
    end.

retransmit_downlink(DevAddr) ->
    case mnesia:dirty_read(pending, DevAddr) of
        [] ->
            {false, undefined};
        [Msg] ->
            {true, Msg#pending.phypayload}
    end.

repeat_downlink(DevAddr, ACK) ->
    case mnesia:dirty_read(pending, DevAddr) of
        [] ->
            {false, undefined};
        [#pending{confirmed=true} = Msg] when ACK == 0 ->
            {true, Msg#pending.phypayload};
        [_Msg] ->
            ok = mnesia:dirty_delete(pending, DevAddr),
            {false, undefined}
    end.

send_unicast(TxQ, DevAddr, ACK, FOpts, #txdata{confirmed=false} = TxData) ->
    PHYPayload = encode_unicast(2#011, DevAddr, ACK, FOpts, TxData),
    mnesia:dirty_write(pending, #pending{devaddr=DevAddr, confirmed=false, phypayload=PHYPayload}),
    {send, TxQ, PHYPayload};
send_unicast(TxQ, DevAddr, ACK, FOpts, #txdata{confirmed=true} = TxData) ->
    PHYPayload = encode_unicast(2#101, DevAddr, ACK, FOpts, TxData),
    mnesia:dirty_write(pending, #pending{devaddr=DevAddr, confirmed=true, phypayload=PHYPayload}),
    {send, TxQ, PHYPayload}.

send_multicast(TxQ, DevAddr, #txdata{confirmed=false} = TxData) ->
    % must be unconfirmed, ACK=0, no MAC commands allowed
    PHYPayload = encode_multicast(2#011, DevAddr, TxData),
    {send, TxQ, PHYPayload};
send_multicast(_TxQ, _DevAddr, #txdata{confirmed=true}) ->
    {error, not_allowed}.

encode_unicast(MType, DevAddr, ACK, FOpts, TxData) ->
    {atomic, L} = mnesia:transaction(
        fun() ->
            [D] = mnesia:read(links, DevAddr, write),
            FCnt = (D#link.fcntdown + 1) band 16#FFFFFFFF,
            NewD = D#link{fcntdown=FCnt},
            mnesia:write(links, NewD, write),
            NewD
        end),
    encode_frame(MType, DevAddr, L#link.nwkskey, L#link.appskey,
        L#link.fcntdown, get_adr_flag(L), ACK, FOpts, TxData).

encode_multicast(MType, DevAddr, TxData) ->
    {atomic, G} = mnesia:transaction(
        fun() ->
            [D] = mnesia:read(multicast_groups, DevAddr, write),
            FCnt = (D#multicast_group.fcntdown + 1) band 16#FFFFFFFF,
            NewD = D#multicast_group{fcntdown=FCnt},
            mnesia:write(multicast_groups, NewD, write),
            NewD
        end),
    encode_frame(MType, DevAddr, G#multicast_group.nwkskey, G#multicast_group.appskey,
        G#multicast_group.fcntdown, 0, 0, <<>>, TxData).

encode_frame(MType, DevAddr, NwkSKey, AppSKey, FCnt, ADR, ACK, FOpts, #txdata{port=FPort, data=Data, pending=FPending}) ->
    FHDR = <<(reverse(DevAddr)):4/binary, ADR:1, 0:1, ACK:1, (bool_to_bit(FPending)):1, (byte_size(FOpts)):4,
        FCnt:16/little-unsigned-integer, FOpts/binary>>,
    MACPayload = case FPort of
        undefined when Data == undefined; Data == <<>> ->
            <<FHDR/binary>>;
        undefined ->
            lager:warning("Ignored application data without a Port number"),
            <<FHDR/binary>>;
        0 ->
            FRMPayload = cipher(Data, NwkSKey, 1, DevAddr, FCnt),
            <<FHDR/binary, 0:8, (reverse(FRMPayload))/binary>>;
        Num when Num > 0 ->
            FRMPayload = cipher(Data, AppSKey, 1, DevAddr, FCnt),
            <<FHDR/binary, FPort:8, (reverse(FRMPayload))/binary>>
    end,
    Msg = <<MType:3, 0:3, 0:2, MACPayload/binary>>,
    MIC = aes_cmac:aes_cmac(NwkSKey, <<(b0(1, DevAddr, FCnt, byte_size(Msg)))/binary, Msg/binary>>, 4),
    <<Msg/binary, MIC/binary>>.

bool_to_bit(true) -> 1;
bool_to_bit(false) -> 0.

get_adr_flag(#link{adr_flag_set=ADR}) when ADR == undefined; ADR == 0 -> 0;
get_adr_flag(#link{adr_flag_set=ADR}) when ADR > 0 -> 1.


cipher(Bin, Key, Dir, DevAddr, FCnt) ->
    cipher(Bin, Key, Dir, DevAddr, FCnt, 1, <<>>).

cipher(<<Block:16/binary, Rest/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    cipher(Rest, Key, Dir, DevAddr, FCnt, I+1, <<(binxor(Block, Si, <<>>))/binary, Acc/binary>>);
cipher(<<>>, _Key, _Dir, _DevAddr, _FCnt, _I, Acc) -> Acc;
cipher(<<LastBlock/binary>>, Key, Dir, DevAddr, FCnt, I, Acc) ->
    Si = crypto:block_encrypt(aes_ecb, Key, ai(Dir, DevAddr, FCnt, I)),
    <<(binxor(LastBlock, binary:part(Si, 0, byte_size(LastBlock)), <<>>))/binary, Acc/binary>>.

ai(Dir, DevAddr, FCnt, I) ->
    <<16#01, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, I>>.

b0(Dir, DevAddr, FCnt, Len) ->
    <<16#49, 0,0,0,0, Dir, (reverse(DevAddr)):4/binary, FCnt:32/little-unsigned-integer, 0, Len>>.

binxor(<<>>, <<>>, Acc) -> Acc;
binxor(<<A, RestA/binary>>, <<B, RestB/binary>>, Acc) ->
    binxor(RestA, RestB, <<(A bxor B), Acc/binary>>).

reverse(Bin) -> reverse(Bin, <<>>).
reverse(<<>>, Acc) -> Acc;
reverse(<<H:1/binary, Rest/binary>>, Acc) ->
    reverse(Rest, <<H/binary, Acc/binary>>).

padded(Bytes, Msg) ->
    case bit_size(Msg) rem (8*Bytes) of
        0 -> Msg;
        N -> <<Msg/bitstring, 0:(8*Bytes-N)>>
    end.

% stackoverflow.com/questions/3768197/erlang-ioformatting-a-binary-to-hex
% a little magic from http://stackoverflow.com/users/2760050/himangshuj
binary_to_hex(undefined) ->
    undefined;
binary_to_hex(Id) ->
    << <<Y>> || <<X:4>> <= Id, Y <- integer_to_list(X,16)>>.

hex_to_binary(undefined) ->
    undefined;
hex_to_binary(Id) ->
    <<<<Z>> || <<X:8,Y:8>> <= Id,Z <- [binary_to_integer(<<X,Y>>,16)]>>.

% end of file
