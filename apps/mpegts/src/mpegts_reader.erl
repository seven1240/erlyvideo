%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010 Max Lapshin
%%% @doc        MPEG TS demuxer module
%%% @reference  See <a href="http://erlyvideo.org" target="_top">http://erlyvideo.org</a> for more information
%%% @end
%%%
%%% This file is part of erlang-mpegts.
%%% 
%%% erlang-mpegts is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlang-mpegts is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlang-mpegts.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(mpegts_reader).
-author('Max Lapshin <max@maxidoors.ru>').

-include_lib("erlmedia/include/h264.hrl").
-include_lib("erlmedia/include/aac.hrl").
-include("log.hrl").
-include("../include/mpegts.hrl").

-include_lib("erlmedia/include/video_frame.hrl").


-export([benchmark/0]).

-define(PID_TYPE(Pid), case lists:keyfind(Pid, #stream.pid, Pids) of #stream{codec = h264} -> "V"; _ -> "A" end).

-on_load(load_nif/0).


-record(decoder, {
  buffer = <<>>,
  pids = [],
  consumer,
  pmt_pid,
  socket,
  options,
  byte_counter = 0
}).

-record(mpegts_pat, {
  descriptors
}).


-record(stream, {
  pid,
  program_num,
  demuxer,
  handler,
  codec,
  synced = false,
  ts_buffer = [],
  es_buffer = <<>>,
  counter = 0,
  pcr,
  start_dts,
  dts,
  pts,
  video_config = undefined,
  send_audio_config = false,
  sample_rate,
  h264
}).

-export([extract_nal/1]).

-export([start_link/1, set_socket/2]).
-export([init/1, handle_info/2, handle_call/3, handle_cast/2, code_change/3, terminate/2]).

-export([decode/2, decode_ts/2, decode_pes/2]).


load_nif() ->
  Load = erlang:load_nif(code:lib_dir(mpegts,ebin)++ "/mpegts_reader", 0),
  io:format("Load mpegts_reader: ~p~n", [Load]),
  ok.


start_link(Options) ->
  gen_server:start_link(?MODULE, [Options], []).

set_socket(Reader, Socket) when is_pid(Reader) andalso is_port(Socket) ->
  gen_tcp:controlling_process(Socket, Reader),
  gen_server:call(Reader, {set_socket, Socket}).

init([Options]) ->
  Consumer = case proplists:get_value(consumer, Options) of
    undefined -> undefined;
    Cons when is_pid(Cons) ->
      erlang:monitor(process, Cons),
      Cons
  end,
  {ok, #decoder{consumer = Consumer, options = Options}}.



handle_call({set_socket, Socket}, _From, #decoder{} = Decoder) ->
  inet:setopts(Socket, [{packet,raw},{active,once}]),
  % ?D({passive_accepted, Socket}),
  {reply, ok, Decoder#decoder{socket = Socket}};


handle_call(connect, _From, #decoder{options = Options} = Decoder) ->
  URL = proplists:get_value(url, Options),
  Timeout = proplists:get_value(timeout, Options, 2000),
  {Schema, _, _Host, _Port, _Path, _Query} = http_uri2:parse(URL),
  {ok, Socket} = case Schema of
    udp -> 
      connect_udp(URL);
    _ ->
      {ok, _Headers, Sock} = http_stream:get(URL, [{timeout,Timeout}]),
      inet:setopts(Sock, [{packet,raw},{active,once}]),
      {ok, Sock}
  end,
  ?D({connected, URL, Socket}),
  {reply, ok, Decoder#decoder{socket = Socket}};

handle_call(Call, _From, State) ->
  {stop, {unknown_call, Call}, State}.
  
handle_info({'DOWN', _Ref, process, Consumer, _Reason}, #decoder{consumer = Consumer} = State) ->
  {stop, normal, State};
  
handle_info({'DOWN', _Ref, process, _Pid, Reason}, #decoder{} = State) ->
  ?D({"MPEG TS reader lost pid handler", _Pid}),
  {stop, Reason, State};


handle_info({udp, Socket, _IP, _InPortNo, Bin}, #decoder{consumer = Consumer} = Decoder) ->
  inet:setopts(Socket, [{active,once}]),
  {ok, Decoder1, Frames} = decode(Bin, Decoder),
  [Consumer ! Frame || Frame <- Frames],
  {noreply, Decoder1};
  
handle_info({tcp, Socket, Bin}, #decoder{consumer = Consumer} = Decoder) ->
  inet:setopts(Socket, [{active,once}]),
  {ok, Decoder1, Frames} = decode(Bin, Decoder),
  [Consumer ! Frame || Frame <- Frames],
  {noreply, Decoder1};
  
handle_info({tcp_closed, _Socket}, Decoder) ->
  {stop, normal, Decoder};

handle_info({data, Bin}, #decoder{consumer = Consumer} = Decoder) ->
  {ok, Decoder1, Frames} = decode(Bin, Decoder),
  [Consumer ! Frame || Frame <- Frames],
  {noreply, Decoder1};

handle_info(Else, Decoder) ->
  {stop, {unknown_message, Else}, Decoder}.


handle_cast(Cast, Decoder) ->
  {stop, {unknown_cast, Cast}, Decoder}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

    
connect_udp(URL) ->
  {_, _, Host, Port, _Path, _Query} = http_uri2:parse(URL),
  {ok, Addr} = inet_parse:address(Host),
  {ok, Socket} = gen_udp:open(Port, [binary,{active,once},{recbuf,65536},inet,{ip,Addr}]),
  {ok, Socket}.
  


decode(Bin, #decoder{buffer = <<>>} = Decoder) when is_binary(Bin) ->
  decode(Bin, Decoder#decoder{}, []);

decode(Bin, #decoder{buffer = Buffer} = Decoder) when is_binary(Bin) ->
  decode(<<Buffer/binary, Bin/binary>>, Decoder, []).

decode(<<16#47, Packet:187/binary, Rest/binary>>, Decoder, Frames) ->
  case decode_ts(Packet, Decoder) of
    {ok, Decoder1, undefined} -> 
      decode(Rest, Decoder1, Frames);
    {ok, Decoder1, PESPacket} -> 
      {ok, Decoder2, Frames1} = decode_pes(Decoder1, PESPacket),
      decode(Rest, Decoder2, Frames ++ Frames1)
  end;

decode(<<_, Bin/binary>>, Decoder, Frames) when size(Bin) >= 374 ->
  % ?D(desync),
  decode(Bin, Decoder, Frames);

decode(Bin, Decoder, Frames) ->
  {ok, Decoder#decoder{buffer = Bin}, Frames}.


decode_ts(<<_:3, ?PAT_PID:13, _/binary>> = Packet, Decoder) ->
  Decoder1 = handle_pat(ts_payload(Packet), Decoder),
  {ok, Decoder1, undefined};

% decode_ts(<<_:3, ?SDT_PID:13, _/binary>> = Packet, Decoder) ->
%   Decoder1 = handle_sdt(ts_payload(Packet), Decoder),
%   {ok, Decoder1, undefined};

decode_ts(<<_:3, PmtPid:13, _/binary>> = Packet, #decoder{pmt_pid = PmtPid} = Decoder) ->
  Decoder1 = pmt(ts_payload(Packet), Decoder),
  {ok, Decoder1, undefined};


decode_ts(<<_Error:1, PayloadStart:1, _TransportPriority:1, Pid:13, _Scrambling:2,
            _HasAdaptation:1, _HasPayload:1, _Counter:4, _/binary>> = Packet, #decoder{pids = Pids} = Decoder) ->
  PCR = get_pcr(Packet),
  % io:format("ts: ~p (~p) ~p~n", [Pid,PayloadStart, _Counter]),
  case lists:keytake(Pid, #stream.pid, Pids) of
    {value, #stream{synced = false}, _} when PayloadStart == 0 ->
      ?D({"Not synced pes", Pid}),
      {ok, Decoder, undefined};
    {value, #stream{synced = false} = Stream, Streams} when PayloadStart == 1 ->
      ?D({"Synced PES", Pid}),
      {ok, Decoder#decoder{pids = [Stream#stream{synced = true, pcr = PCR, ts_buffer = [ts_payload(Packet)]}|Streams]}, undefined};
    {value, #stream{synced = true, ts_buffer = Buf} = Stream, Streams} when PayloadStart == 0 ->
      {ok, Decoder#decoder{pids = [Stream#stream{pcr = PCR, ts_buffer = [ts_payload(Packet)|Buf]}|Streams]}, undefined};
    {value, #stream{synced = true, ts_buffer = Buf} = Stream, Streams} when PayloadStart == 1 ->  
      Body = iolist_to_binary(lists:reverse(Buf)),
      Stream1 = stream_timestamp(Body, Stream#stream{pcr = PCR}),
      PESPacket = pes_packet(Body, Stream1),
      {ok, Decoder#decoder{pids = [Stream1#stream{ts_buffer = [ts_payload(Packet)], es_buffer = <<>>}|Streams]}, PESPacket};
    false ->
      % ?D({unknown_pid, Pid}),
      {ok, Decoder, undefined}
  end;

decode_ts({eof,Codec}, #decoder{pids = Pids} = Decoder) ->
  case lists:keytake(Codec, #stream.codec, Pids) of
    {value, #stream{ts_buffer = Buf} = Stream, Streams} ->
      Body = iolist_to_binary(lists:reverse(Buf)),
      % ?D({eof,Codec,Body}),
      Stream1 = stream_timestamp(Body, Stream),
      PESPacket = pes_packet(Body, Stream1),
      {ok, Decoder#decoder{pids = [Stream1#stream{ts_buffer = [], es_buffer = <<>>}|Streams]}, PESPacket};
    false ->
      % ?D({unknown_pid, Pid}),
      {ok, Decoder, undefined}
  end.    

ts_payload(<<_TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 0:1, 1:1, _Counter:4, Payload/binary>>)  -> 
  Payload;

ts_payload(<<_TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 1:1, 1:1, _Counter:4, 
              AdaptationLength, _AdaptationField:AdaptationLength/binary, Payload/binary>>) -> 
  Payload;

ts_payload(<<_TEI:1, _Start:1, _Priority:1, _Pid:13, _Scrambling:2, 
              _Adaptation:1, 0:1, _Counter:4, _Payload/binary>>)  ->
  ?D({"Empty payload on pid", _Pid}),
  <<>>.


get_pcr(<<_:18, 1:1, _:5, Length, AdaptationField:Length/binary, _/binary>>) when Length > 0 ->
  extract_pcr(AdaptationField);
  
get_pcr(_) ->
  undefined.

extract_pcr(<<_Discontinuity:1, _RandomAccess:1, _Priority:1, PCR:1, _OPCR:1, _Splice:1, _Private:1, _Ext:1, Pcr1:33, Pcr2:9, _/bitstring>>) when PCR == 1 ->
  Pcr1 / 90 + Pcr2 / 27000;
extract_pcr(_) ->
  undefined.



%%%%%%%%%%%%%%%   Program access table  %%%%%%%%%%%%%%

handle_pat(PATBin, #decoder{pmt_pid = undefined, options = Options} = Decoder) ->
  % ?D({"Full PAT", size(PATBin), PATBin}),
  #mpegts_pat{descriptors = Descriptors} = pat(PATBin),
  ?D({pat, Descriptors}),
  PmtPid = select_pmt_pid(Descriptors, proplists:get_value(program, Options)),
  Decoder#decoder{pmt_pid = PmtPid};


handle_pat(_PATBin, Decoder) ->
  Decoder.


select_pmt_pid([{PmtPid, _ProgramNum}], undefined) -> % Means no program specified and only one in stream
  PmtPid;
select_pmt_pid(Descriptors, SelectedProgram) ->
  case lists:keyfind(SelectedProgram, 1, Descriptors) of
    {PmtPid, SelectedProgram} -> PmtPid;
    _ ->
      ?D({"Has many programs in MPEG-TS, don't know which to choose", Descriptors}),
      undefined
  end.
  

pat(<<_PtField, 0, 2#10:2, 2#11:2, Length:12, _Misc:5/binary, PAT/binary>> = _PATBin) -> % PAT
  ProgramCount = round((Length - 5)/4) - 1,
  % io:format("PAT: ~p programs (~p)~n", [ProgramCount, size(PAT)]),
  % ?D({"PAT descriptors", ProgramCount, PAT}),
  Descriptors = extract_pat(PAT, ProgramCount, []),
  #mpegts_pat{descriptors = Descriptors}.



extract_pat(<<_CRC32/binary>>, 0, Descriptors) ->
  lists:keysort(#stream.pid, Descriptors);
  
extract_pat(<<ProgramNum:16, _:3, Pid:13, PAT/binary>>, ProgramCount, Descriptors) ->
  extract_pat(PAT, ProgramCount - 1, [{Pid, ProgramNum} | Descriptors]).


% handle_sdt(<<TableId, _SectionInd:1, _:3, SectionLength:12, TransportStreamId:16, _:2, _Version:5, _CurrentNext:1, 
%              _SectionNumber, _LastSectionNumber, _OriginalNetId:16, _:8, SDT/binary>> = _Bin, Decoder) ->
%   io:format("~p~n", [[{table,TableId},{section_len,SectionLength},{ts_id,TransportStreamId},
%      {section_number,_SectionNumber},{sdt_size,size(SDT)},{sdt,SDT}
%      
%      ]]),
%   Decoder.
% 

pmt(<<_Pointer, 2, _SectionInd:1, 0:1, 2#11:2, SectionLength:12, 
    ProgramNum:16, _:2, _Version:5, _CurrentNext:1, _SectionNumber,
    _LastSectionNumber, _Some:3, _PCRPID:13, _Some2:4, ProgramInfoLength:12, 
    _ProgramInfo:ProgramInfoLength/binary, PMT/binary>> = _PMTBin, #decoder{pids = []} = Decoder) ->
  % ?D({"PMT", size(PMTBin), PMTBin, SectionLength - 13, size(PMT), PMT}),
  PMTLength = round(SectionLength - 13 - ProgramInfoLength),
  % ?D({"Selecting MPEG-TS program", ProgramNum}),
  % io:format("Program info: ~p~n", [_ProgramInfo]),
  % ?D({"PMT", size(PMT), PMTLength, _ProgramInfo}),
  Descriptors = extract_pmt(PMT, PMTLength, []),
  % io:format("Streams: ~p~n", [Descriptors]),
  Descriptors1 = lists:map(fun(#stream{} = Stream) ->
    Stream#stream{program_num = ProgramNum, h264 = #h264{}}
  end, Descriptors),
  % AllPids = [self() | lists:map(fun(A) -> element(#stream_out.handler, A) end, Descriptors1)],
  % eprof:start(),
  % eprof:start_profiling(AllPids),
  % Decoder#decoder{pids = lists:keymerge(#stream.pid, Pids, Descriptors1)}.
  Decoder#decoder{pids = Descriptors1};

pmt(_PMT, Decoder) ->
  Decoder.

extract_pmt(_CRC32, 0, Descriptors) ->
  % ?D({"Left CRC32", _CRC32}),
  % io:format("Unknown PMT: ~p~n", [PMT]),
  lists:keysort(#stream.pid, Descriptors);

extract_pmt(<<StreamType, 2#111:3, Pid:13, _:4, ESLength:12, _ES:ESLength/binary, Rest/binary>>, PMTLength, Descriptors) ->
  ?D({"Pid -> Type", Pid, StreamType, _ES}),
  extract_pmt(Rest, PMTLength - 5 - ESLength, [#stream{handler = pes, counter = 0, pid = Pid, codec = stream_codec(StreamType)}|Descriptors]).
  


stream_codec(?TYPE_VIDEO_H264) -> h264;
stream_codec(?TYPE_VIDEO_MPEG2) -> mpeg2video;
stream_codec(?TYPE_AUDIO_AAC) -> aac;
stream_codec(?TYPE_AUDIO_AAC2) -> aac;
stream_codec(?TYPE_AUDIO_MPEG1) -> mp3;
stream_codec(?TYPE_AUDIO_MPEG2) -> mpeg2audio;
stream_codec(Type) -> ?D({"Unknown TS PID type", Type}), unhandled.


pes_packet(_, #stream{codec = unhandled}) -> 
  undefined;

pes_packet(_, #stream{dts = undefined}) ->
  ?D({"No PCR or DTS yes"}),
  undefined;

pes_packet(<<1:24, _:5/binary, Length, _PESHeader:Length/binary, Data/binary>>, 
           #stream{es_buffer = <<>>, codec = Codec, pid = Pid, dts = DTS, pts = PTS}) ->
  #pes_packet{pid = Pid, codec = Codec, dts = DTS, pts = PTS, body = Data};

pes_packet(<<1:24, _:5/binary, Length, _PESHeader:Length/binary, Data/binary>>, 
           #stream{es_buffer = Buffer, codec = Codec, pid = Pid, dts = DTS, pts = PTS}) ->
  #pes_packet{pid = Pid, codec = Codec, dts = DTS, pts = PTS, body = <<Buffer/binary, Data/binary>>}.



decode_pes(#decoder{pids = Pids} = Decoder, #pes_packet{body = Body, pid = Pid}) ->
  case lists:keytake(Pid, #stream.pid, Pids) of
    {value, Stream, Streams} ->
      % ?D({decode_pes,Stream#stream.codec}),
      {Stream1, Frames} = decode_pes_packet(Stream#stream{es_buffer = Body}),
      {ok, Decoder#decoder{pids = [Stream1|Streams]}, Frames};
    _ ->
      {ok, Decoder}
  end.  


decode_pes_packet(#stream{codec = aac} = Packet) ->
  decode_aac(Packet);
  
decode_pes_packet(#stream{codec = h264} = Packet) ->
  decode_avc(Packet, []);


decode_pes_packet(#stream{codec = mp3, dts = DTS, pts = PTS, es_buffer = Data} = Stream) ->
  AudioFrame = #video_frame{       
    content = audio,
    flavor  = frame,
    dts     = DTS,
    pts     = PTS,
    body    = Data,
	  codec	  = mp3,
	  sound	  = {stereo, bit16, rate44}
  },
  % ?D({audio, Stream#stream.pcr, DTS}),
  {Stream, [AudioFrame]};

decode_pes_packet(#stream{codec = mpeg2audio, dts = DTS, pts = PTS, es_buffer = Data} = Stream) ->
  AudioFrame = #video_frame{       
    content = audio,
    flavor  = frame,
    dts     = DTS,
    pts     = PTS,
    body    = Data,
	  codec	  = mpeg2audio,
	  sound	  = {stereo, bit16, rate44}
  },
  % ?D({audio, Stream#stream.pcr, DTS}),
  {Stream, [AudioFrame]};


decode_pes_packet(#stream{dts = DTS, pts = PTS, es_buffer = Block, codec = mpeg2video} = Stream) ->
  VideoFrame = #video_frame{       
    content = video,
    flavor  = frame,
    dts     = DTS,
    pts     = PTS,
    body    = Block,
	  codec	  = mpeg2video
  },
  {Stream, [VideoFrame]}.
  % decode_mpeg2_video(Stream, []).
  
pes_timestamp(<<_:7/binary, 2#11:2, _:6, PESHeaderLength, PESHeader:PESHeaderLength/binary, _/binary>>) ->
  <<2#0011:4, Pts1:3, 1:1, Pts2:15, 1:1, Pts3:15, 1:1, 
    2#0001:4, Dts1:3, 1:1, Dts2:15, 1:1, Dts3:15, 1:1, _Rest/binary>> = PESHeader,
  <<PTS1:33>> = <<Pts1:3, Pts2:15, Pts3:15>>,
  <<DTS1:33>> = <<Dts1:3, Dts2:15, Dts3:15>>,
  {DTS1 / 90, PTS1 / 90};

pes_timestamp(<<_:7/binary, 2#10:2, _:6, PESHeaderLength, PESHeader:PESHeaderLength/binary, _/binary>>) ->
  <<2#0010:4, Pts1:3, 1:1, Pts2:15, 1:1, Pts3:15, 1:1, _Rest/binary>> = PESHeader,
  <<PTS1:33>> = <<Pts1:3, Pts2:15, Pts3:15>>,
  % ?D({pts, PTS1}),
  {undefined, PTS1/90};

pes_timestamp(_) ->
  {undefined, undefined}.
  
stream_timestamp(PES, Stream) ->
  {DTS, PTS} = pes_timestamp(PES),
  % ?D({Stream#stream.pid, DTS, PTS}),
  guess_timestamp(DTS, PTS, Stream).
  
  
guess_timestamp(DTS, PTS, Stream) when is_number(DTS) andalso is_number(PTS) ->
  normalize_timestamp(Stream#stream{dts = DTS, pts = PTS});
  
guess_timestamp(undefined, PTS, Stream) when is_number(PTS) ->
  normalize_timestamp(Stream#stream{dts = PTS, pts = PTS});

% FIXME!!!
% Here is a HUGE hack. VLC give me stream, where are no DTS or PTS, only PCR, once a second,
% thus I increment timestamp counter on each NAL, assuming, that there is 25 FPS.
% This is very, very wrong, but I really don't know how to calculate it in other way.
% stream_timestamp(_, #stream{pcr = PCR} = Stream, _) when is_number(PCR) ->
%   % ?D({"Set DTS to PCR", PCR}),
%   normalize_timestamp(Stream#stream{dts = PCR, pts = PCR});
guess_timestamp(undefined, undefined, #stream{dts = DTS, pts = PTS, pcr = PCR, start_dts = Start} = Stream) when is_number(PCR) andalso is_number(DTS) andalso is_number(Start) andalso PCR == DTS + Start ->
  % ?D({"Increasing", DTS}),
  Stream#stream{dts = DTS + 40, pts = PTS + 40};
  % Stream;

guess_timestamp(undefined, undefined, #stream{dts = DTS, pts = PTS, pcr = undefined} = Stream) when is_number(DTS) andalso is_number(PTS) ->
  ?D({none, PTS, DTS}),
  % ?D({"Have no timestamps", DTS}),
  Stream#stream{dts = DTS + 40, pts = PTS + 40};

guess_timestamp(undefined, undefined,  #stream{pcr = PCR, start_dts = undefined} = Stream) when is_number(PCR) ->
  guess_timestamp(undefined, undefined,  Stream#stream{start_dts = 0});

guess_timestamp(undefined, undefined,  #stream{pcr = PCR} = Stream) when is_number(PCR) ->
  % ?D({no_dts, PCR, Stream#stream.dts, Stream#stream.start_dts, Stream#stream.pts}),
  % ?D({"No DTS, taking", PCR - (Stream#stream.dts + Stream#stream.start_dts), PCR - (Stream#stream.pts + Stream#stream.start_dts)}),
  normalize_timestamp(Stream#stream{pcr = PCR, dts = PCR, pts = PCR});
  
guess_timestamp(undefined, undefined, #stream{pcr = undefined, dts = undefined} = Stream) ->
  ?D({"No timestamps at all"}),
  Stream.


% normalize_timestamp(Stream) -> Stream;
% normalize_timestamp(#stream{start_dts = undefined, dts = DTS} = Stream) when is_number(DTS) -> 
%   normalize_timestamp(Stream#stream{start_dts = DTS});
% normalize_timestamp(#stream{start_dts = undefined, pts = PTS} = Stream) when is_number(PTS) -> 
%   normalize_timestamp(Stream#stream{start_dts = PTS});

% normalize_timestamp(#stream{start_dts = undefined, pcr = PCR} = Stream) when is_number(PCR) -> 
%   normalize_timestamp(Stream#stream{start_dts = PCR});
% 
% normalize_timestamp(#stream{start_dts = undefined, dts = DTS} = Stream) when is_number(DTS) andalso DTS > 0 -> 
%   normalize_timestamp(Stream#stream{start_dts = DTS});
% 
% normalize_timestamp(#stream{start_dts = Start, dts = DTS, pts = PTS} = Stream) when is_number(Start) andalso Start > 0 -> 
%   % ?D({"Normalize", Stream#stream.pid, round(DTS - Start), round(PTS - Start)}),
%   Stream#stream{dts = DTS - Start, pts = PTS - Start};
normalize_timestamp(Stream) ->
  Stream.
  
% normalize_timestamp(#stream{start_pcr = 0, pcr = PCR} = Stream) when is_integer(PCR) andalso PCR > 0 -> 
%   Stream#stream{start_pcr = PCR, pcr = 0};
% normalize_timestamp(#stream{start_pcr = Start, pcr = PCR} = Stream) -> 
%   Stream#stream{pcr = PCR - Start}.
% normalize_timestamp(Stream) -> Stream.



decode_aac(#stream{send_audio_config = false, es_buffer = AAC, dts = DTS} = Stream) ->
  Config = aac:adts_to_config(AAC),
  #aac_config{sample_rate = SampleRate} = aac:decode_config(Config),
  AudioConfig = #video_frame{       
   	content = audio,
   	flavor  = config,
		dts     = DTS,
		pts     = DTS,
		body    = Config,
	  codec	  = aac,
	  sound	  = {stereo, bit16, rate44}
	},
	{Stream1, Frames} = decode_aac(Stream#stream{send_audio_config = true, sample_rate = SampleRate}),
	{Stream1, [AudioConfig] ++ Frames};
  

decode_aac(#stream{es_buffer = ADTS, dts = DTS, sample_rate = SampleRate} = Stream) ->
  {Frames, Rest} = decode_adts(ADTS, DTS, SampleRate / 1000, 0, []),
  {Stream#stream{es_buffer = Rest}, Frames}.

decode_adts(<<>>, _BaseDTS, _SampleRate, _SampleCount, Frames) ->
  {lists:reverse(Frames), <<>>};

decode_adts(ADTS, BaseDTS, SampleRate, SampleCount, Frames) ->
  case aac:unpack_adts(ADTS) of
    {ok, Frame, Rest} ->
      DTS = BaseDTS + SampleCount / SampleRate,
      AudioFrame = #video_frame{       
        content = audio,
        flavor  = frame,
        dts     = DTS,
        pts     = DTS,
        body    = Frame,
    	  codec	  = aac,
    	  sound	  = {stereo, bit16, rate44}
      },
      % ?D({audio, Stream#stream.pcr, DTS}),
      decode_adts(Rest, BaseDTS, SampleRate, SampleCount + 1024, [AudioFrame|Frames]);
    {more, _} ->
      {lists:reverse(Frames), ADTS}
  end.
      
% decode_aac(#stream{es_buffer = <<_Syncword:12, _ID:1, _Layer:2, 0:1, _Profile:2, _Sampling:4,
%                                  _Private:1, _Channel:3, _Original:1, _Home:1, _Copyright:1, _CopyrightStart:1,
%                                  _FrameLength:13, _ADTS:11, _Count:2, _CRC:16, Rest/binary>>} = Stream) ->
%   send_aac(Stream#stream{es_buffer = Rest});
% 
% decode_aac(#stream{es_buffer = <<_Syncword:12, _ID:1, _Layer:2, _ProtectionAbsent:1, _Profile:2, _Sampling:4,
%                                  _Private:1, _Channel:3, _Original:1, _Home:1, _Copyright:1, _CopyrightStart:1,
%                                  _FrameLength:13, _ADTS:11, _Count:2, Rest/binary>>} = Stream) ->
%   % ?D({"AAC", Syncword, ID, Layer, ProtectionAbsent, Profile, Sampling, Private, Channel, Original, Home,
%   % Copyright, CopyrightStart, FrameLength, ADTS, Count}),
%   % ?D({"AAC", Rest}),
%   send_aac(Stream#stream{es_buffer = Rest}).
% 
% send_aac(#stream{es_buffer = Data, consumer = Consumer, dts = DTS, pts = PTS} = Stream) ->
%   % ?D({audio, }),
%   Stream#stream{es_buffer = <<>>}.
%   

decode_avc(#stream{es_buffer = Data} = Stream, Frames) ->
  case extract_nal(Data) of
    undefined ->
      {Stream, Frames};
    {ok, NAL, Rest} ->
      % ?D(NAL),
      {Stream1, Frames1} = handle_nal(Stream#stream{es_buffer = Rest}, NAL),
      decode_avc(Stream1, Frames ++ Frames1)
  end.

% 
% decode_mpeg2_video(#stream{dts = DTS, pts = PTS, es_buffer = Data} = Stream, Frames) ->
%   case extract_nal(Data) of
%     undefined ->
%       {Stream, Frames};
%     {ok, Block, Rest} ->
%       VideoFrame = #video_frame{       
%         content = video,
%         flavor  = frame,
%         dts     = DTS,
%         pts     = PTS,
%         body    = Block,
%         codec   = mpeg2video
%       },
%       ?D({mpeg2video,size(Block),DTS}),
%       % ?D({video, round(DTS), size(Data)}),
%       decode_mpeg2_video(Stream#stream{es_buffer = Rest}, [VideoFrame|Frames])
%   end.

  

handle_nal(Stream, <<_:3, 9:5, _/binary>>) ->
  {Stream, []};

handle_nal(#stream{dts = DTS, pts = PTS, h264 = H264} = Stream, NAL) ->
  {H264_1, Frames} = h264:decode_nal(NAL, H264),
  ConfigFrames = case {h264:has_config(H264), h264:has_config(H264_1)} of
    {false, true} -> 
      Config = h264:video_config(H264_1),
      [Config#video_frame{dts = DTS, pts = DTS}];
    _ -> []
  end,
  {Stream#stream{h264 = H264_1}, [Frame#video_frame{dts = DTS, pts = PTS} || Frame <- Frames] ++ ConfigFrames}.


extract_nal(Data) -> extract_nal_erl(Data).

extract_nal_erl(Data) ->
  find_nal_start_erl(Data).

find_nal_start_erl(<<1:32, Rest/binary>>) ->
  find_and_extract_nal(Rest);

find_nal_start_erl(<<1:24, Rest/binary>>) ->
  find_and_extract_nal(Rest);

find_nal_start_erl(<<>>) ->
  undefined;
  
find_nal_start_erl(<<_, Rest/binary>>) ->
  find_nal_start_erl(Rest).

find_and_extract_nal(Bin) ->
  case find_nal_end_erl(Bin, 0) of
    undefined -> undefined;
    Length ->
      <<NAL:Length/binary, Rest/binary>> = Bin,
      {ok, NAL, Rest}
  end.    
  
  
find_nal_end_erl(<<1:32, _/binary>>, Len) -> Len;
find_nal_end_erl(<<1:24, _/binary>>, Len) -> Len;
find_nal_end_erl(<<>>, _Len) -> undefined;
find_nal_end_erl(<<_, Rest/binary>>, Len) -> find_nal_end_erl(Rest, Len+1).


      


-include_lib("eunit/include/eunit.hrl").

benchmark() ->
  N = 100000,
  extract_nal_erl_bm(N),
  extract_nal_c_bm(N).

nal_test_bin(large) ->
  <<0,0,0,1,
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %54
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %104
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %154
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %204
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %254
    0,0,0,1,
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9, %308
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %358
    0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,0,1,2,3,4,5,6,7,8,9,  %408
    0,0,0,1>>;

nal_test_bin(filler) ->
  <<0,0,0,1,9,80,
    0,0,0,1,6,0,1,192,128,
    0,0,0,1,6,1,1,36,128,
    0,0,0,1,1,174,15,3,234,95,253,83,176,
              187,255,13,246,196,189,93,100,111,80,30,30,167,
              220,41,236,119,135,93,159,204,2,57,132,207,28,
              91,54,128,228,85,112,81,129,18,140,99,90,53,128,
    0,0,0,1,12,255,255,255,255,255,255,255,255,255,255,255,255,255,128,
    0,0,0,1,12,255,255,255,255,255,255,255,255,255,255,255,255,255,255,0,0,1>>;                                                                                            
  
nal_test_bin(small) ->
  <<0,0,0,1,9,224,0,0,1,104,206,50,200>>.

extract_nal_test() ->
  ?assertEqual(undefined, extract_nal(<<0,0,1,9,224>>)),
  ?assertEqual({ok, <<9,224>>, <<0,0,1,104,206,50,200>>}, extract_nal(nal_test_bin(small))),
  ?assertEqual({ok, <<104,206,50,200>>, <<0,0,1>>}, extract_nal(<<0,0,1,104,206,50,200,0,0,1>>)),
  ?assertEqual(undefined, extract_nal(<<>>)).
  
extract_nal_erl_test() ->  
  ?assertEqual({ok, <<9,224>>, <<0,0,1,104,206,50,200>>}, extract_nal_erl(nal_test_bin(small))),
  ?assertEqual({ok, <<104,206,50,200>>, <<0,0,1>>}, extract_nal_erl(<<0,0,0,1,104,206,50,200,0,0,1>>)),
  ?assertEqual(undefined, extract_nal_erl(<<>>)).

extract_real_nal_test() ->
  Bin = nal_test_bin(filler),
  {ok, <<9,80>>, Bin1} = extract_nal(Bin),
  {ok, <<6,0,1,192,128>>, Bin2} = extract_nal(Bin1),
  {ok, <<6,1,1,36,128>>, Bin3} = extract_nal(Bin2),
  {ok, <<1,174,15,3,234,95,253,83,176,
            187,255,13,246,196,189,93,100,111,80,30,30,167,
            220,41,236,119,135,93,159,204,2,57,132,207,28,
            91,54,128,228,85,112,81,129,18,140,99,90,53,128>>, Bin4} = extract_nal(Bin3),
  {ok, <<12,255,255,255,255,255,255,255,255,255,255,255,255,255,128>>, Bin5} = extract_nal(Bin4),
  {ok, <<12,255,255,255,255,255,255,255,255,255,255,255,255,255,255>>, <<0,0,1>>} = extract_nal(Bin5).


extract_nal_erl_bm(N) ->
  Bin = nal_test_bin(large),
  T1 = erlang:now(),
  lists:foreach(fun(_) ->
    extract_nal_erl(Bin)
  end, lists:seq(1,N)),
  T2 = erlang:now(),
  ?D({"Timer erl", timer:now_diff(T2, T1) / N}).

extract_nal_c_bm(N) ->
  Bin = nal_test_bin(large),
  T1 = erlang:now(),
  lists:foreach(fun(_) ->
    extract_nal(Bin)
  end, lists:seq(1,N)),
  T2 = erlang:now(),
  ?D({"Timer native", timer:now_diff(T2, T1) / N}).





