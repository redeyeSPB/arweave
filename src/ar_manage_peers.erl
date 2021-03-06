-module(ar_manage_peers).
-export([update/1, stats/0]).
-include("ar.hrl").

%%% Manage and update peer lists.

%% Print statistics about the current peers.
stats() ->
	Connected = ar_bridge:get_remote_peers(http_bridge_node),
	All = [ Peer || {peer, Peer} <- ar_meta_db:keys() ],
	io:format("Connected peers, in preference order:~n"),
	stats(Connected),
	io:format("Other known peers:~n"),
	stats(All).
stats(Peers) ->
	lists:foreach(
		fun(Peer) -> format_stats(Peer, ar_httpc:get_performance(Peer)) end,
		Peers
	).

%% Pretty(ish) print stats about a node.
format_stats(Peer, Perf) ->
	io:format("\t~s ~.2f kb/s (~p transfers)~n",
		[
			string:pad(ar_util:format_peer(Peer), 20, trailing, $ ),
			(Perf#performance.bytes / 1024) / (Perf#performance.time / 1000000),
			Perf#performance.transfers
		]
	).

%% Return a new peer list, from an old one.
update(Peers) ->
	ar_meta_db:remove_old(os:system_time()),
	{Rankable, Newbies} = partition_newbies(score(get_more_peers(Peers))),
	maybe_drop_peers([ Peer || {Peer, _} <- rank_peers(Rankable) ])
		++ [ Peer || {Peer, newbie} <- Newbies ].

%% Return a new list, with the peers and their peers.
get_more_peers(Peers) ->
	ar_util:unique(
		lists:flatten(
			[
				ar_util:pmap(fun ar_http_iface:get_peers/1, Peers),
				Peers
			]
		)
	).

%% Calculate a score for any given peer or list of peers.
score(Peers) when is_list(Peers) ->
	lists:map(fun(Peer) -> {Peer, score(Peer)} end, Peers);
score(Peer) ->
	case ar_httpc:get_performance(Peer) of
		P when P#performance.transfers < ?PEER_GRACE_PERIOD ->
			newbie;
		P -> P#performance.bytes / P#performance.time
	end.

%% Return a tuple of rankable and newbie peers.
partition_newbies(ScoredPeers) ->
	Newbies = [ P || P = {_, newbie} <- ScoredPeers ],
	{ScoredPeers -- Newbies, Newbies}.

%% Return a ranked list of peers.
rank_peers(ScoredPeers) ->
	lists:sort(fun({_, S1}, {_, S2}) -> S1 >= S2 end, ScoredPeers).

%% Probabalistically drop peers.
maybe_drop_peers(Peers) -> maybe_drop_peers(1, length(Peers), Peers).
maybe_drop_peers(_, _, []) -> [];
maybe_drop_peers(Rank, NumPeers, [Peer|Peers]) when Rank =< ?MINIMUM_PEERS ->
	[Peer|maybe_drop_peers(Rank + 1, NumPeers, Peers)];
maybe_drop_peers(Rank, NumPeers, [Peer|Peers]) ->
	case roll(Rank, NumPeers) of
		true -> [Peer|maybe_drop_peers(Rank + 1, NumPeers, Peers)];
		false -> maybe_drop_peers(Rank + 1, NumPeers, Peers)
	end.

%% Generate a boolean 'drop or not' value from a rank and the number of peers.
roll(Rank, NumPeers) ->
	(rand:uniform(NumPeers - ?MINIMUM_PEERS) - 1)
		> ((Rank - ?MINIMUM_PEERS)/2).