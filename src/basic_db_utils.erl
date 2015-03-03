-module(basic_db_utils).

-compile(export_all).

-include("basic_db.hrl").


make_request_id() ->
    erlang:phash2({self(), os:timestamp()}). % only has to be unique per-pid

-spec primary_node(bkey()) -> index_node().
primary_node(BKey) ->
    DocIdx = riak_core_util:chash_key(BKey),
    {IndexNode, _Type}  = riak_core_apl:first_up(DocIdx, basic_db),
    IndexNode.

-spec replica_nodes(bkey()) -> [index_node()].
replica_nodes(BKey) ->
    DocIdx = riak_core_util:chash_key(BKey),
    [IndexNode || {IndexNode, _Type} <- riak_core_apl:get_primary_apl(DocIdx, ?N, basic_db)].

-spec replica_nodes_indices(key()) -> [index()].
replica_nodes_indices(Key) ->
    [Index || {Index,_Node} <- replica_nodes(Key)].

% -spec get_node_from_index(index()) -> index_node().
% get_node_from_index(Index) ->
%     {ok, Ring} = riak_core_ring_manager:get_my_ring(),
%     Node = riak_core_ring:index_owner(Ring, Index),
%     {Index,Node}.

-spec random_index_node() -> [index_node()].
random_index_node() ->
    % getting the binary consistent hash is more efficient since it lives in a ETS.
    {ok, RingBin} = riak_core_ring_manager:get_chash_bin(),
    IndexNodes = chashbin:to_list(RingBin),
    random_from_list(IndexNodes).

-spec random_index_from_node(node()) -> [index_node()].
random_index_from_node(TargetNode) ->
    % getting the binary consistent hash is more efficient since it lives in a ETS.
    {ok, RingBin} = riak_core_ring_manager:get_chash_bin(),
    Filter = fun ({_Index, Owner}) -> Owner =:= TargetNode end,
    IndexNodes = chashbin:to_list_filter(Filter, RingBin),
    random_from_list(IndexNodes).


%% @doc Returns the nodes that also replicate a subset of keys from some node "NodeIndex".
%% We are assuming a consistent hashing ring, thus we return the N-1 before this node in the
%% ring and the next N-1.
-spec peers(index()) -> [index()].
peers(NodeIndex) ->
    peers(NodeIndex, ?N).
-spec peers(index(), pos_integer()) -> [index_node()].
peers(NodeIndex, N) ->
    % {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    % getting the binary consistent hash is more efficient since it lives in a ETS.
    {ok, RingBin} = riak_core_ring_manager:get_chash_bin(),
    Ring = chashbin:to_chash(RingBin),
    IndexBin = <<NodeIndex:160/integer>>,
    Indices = chash:successors(IndexBin, Ring),
    % PL = riak_core_ring:preflist(IndexBin, Ring),
    % Indices = [Idx || {Idx, _} <- PL],
    RevIndices = lists:reverse(Indices),
    {Succ, _} = lists:split(N-1, Indices),
    {Pred, _} = lists:split(N-1, tl(RevIndices)),
    lists:reverse(Pred) ++ Succ.


%% @doc Returns a random element from a given list.
-spec random_from_list([any()]) -> any().
random_from_list(List) ->
    % properly seeding the process
    <<A:32, B:32, C:32>> = crypto:rand_bytes(12),
    random:seed({A,B,C}),
    % get a random index withing the length of the list
    Index = random:uniform(length(List)),
    % return the element in that index
    lists:nth(Index,List).

-spec encode_kv(term()) -> binary().
encode_kv(Term) ->
    term_to_binary(Term).

-spec decode_kv(binary()) -> term().
decode_kv(Binary) when is_binary(Binary) ->
    binary_to_term(Binary);
decode_kv(Obj) -> Obj.

% pretty print stats
pp(M) ->
    #{
        nodeA                := A   ,
        nodeB                := B   ,
        % start_time           := ST  ,
        % ending_time          := ET  ,
        b2a_number           := OL  ,
        % b2a_size             := SOS ,
        % b2a_size_full        := FOS ,
        keylog_length_b      := KLL ,
        % keylog_size_b        := KLS ,
        % replicated_vv_size_b := VV  ,
        vv_b                 := VV2,
        kl_b                 := KL,
        bvv_b                := BVV
        % rem_entry            := RemoteEntry
        % peers                := Peers
    } = M,
    List = orddict:to_list(VV2),
    VV3 = lists:sort([Val || {_,Val} <- List]),
    List2 = orddict:to_list(BVV),
    BVV2 = lists:sort([Val || {_,Val} <- List2]),
    io:format("\n\n========== SYNC ==========   \n"),
    io:format("\t Node A:                       \t ~p\n",[A]),
    io:format("\t Node B:                       \t ~p\n",[B]),
    % io:format("\t Peers:                        \t ~p\n",[Peers]),
    % io:format("\t Duration (micro):             \t ~p\n",[ET-ST]),
    io:format("\t Objects Transfers:            \t ~p\n",[OL]),
    % io:format("\t Objects Size:                 \t ~p\n",[SOS]),
    % io:format("\t Objects Size Full:            \t ~p\n",[FOS]),
    io:format("\t KeyLog Length:                \t ~p\n",[KLL]),
    % io:format("\t KeyLog Size:                  \t ~p\n",[KLS]),
    % io:format("\t Replicated VV Size:           \t ~p\n",[VV]),
    io:format("\t KeyLog:                       \t ~p\n",[KL]),
    io:format("\t BVV:                          \t ~p\n",[BVV2]),
    io:format("\t VV:                           \t ~p\n\n",[VV3]).
    % io:format("\t Rem Entry:                    \t ~p\n",[RemoteEntry]).


% -spec get_time_sec() -> float().
% get_time_sec() ->
%     {Mega,Sec,Micro} = os:timestamp(),
%     % (Mega * 1000000) + Sec + (Micro / 1000000).
%     Mega * 1000000 * 1000000 + Sec * 1000000 + Micro.





%% From riak_kv_util.erl

-type index_n() :: {index(), pos_integer()}.
-type riak_core_ring() :: riak_core_ring:riak_core_ring().

-spec responsible_preflists(index()) -> [index_n()].
responsible_preflists(Index) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    responsible_preflists(Index, Ring).

-spec responsible_preflists(index(), riak_core_ring()) -> [index_n()].
responsible_preflists(Index, Ring) ->
    AllN = determine_all_n(Ring),
    responsible_preflists(Index, AllN, Ring).

-spec responsible_preflists(index(), [pos_integer(),...], riak_core_ring())
                           -> [index_n()].
responsible_preflists(Index, AllN, Ring) ->
    IndexBin = <<Index:160/integer>>,
    PL = riak_core_ring:preflist(IndexBin, Ring),
    Indices = [Idx || {Idx, _} <- PL],
    RevIndices = lists:reverse(Indices),
    lists:flatmap(fun(N) ->
                          responsible_preflists_n(RevIndices, N)
                  end, AllN).

-spec responsible_preflists_n([index()], pos_integer()) -> [index_n()].
responsible_preflists_n(RevIndices, N) ->
    {Pred, _} = lists:split(N, RevIndices),
    [{Idx, N} || Idx <- lists:reverse(Pred)].


-spec determine_all_n(riak_core_ring()) -> [pos_integer(),...].
determine_all_n(Ring) ->
    Buckets = riak_core_ring:get_buckets(Ring),
    BucketProps = [riak_core_bucket:get_bucket(Bucket, Ring) || Bucket <- Buckets],
    Default = app_helper:get_env(riak_core, default_bucket_props),
    DefaultN = proplists:get_value(n_val, Default),
    AllN = lists:foldl(fun(Props, AllN) ->
                               N = proplists:get_value(n_val, Props),
                               ordsets:add_element(N, AllN)
                       end, [DefaultN], BucketProps),
    AllN.

%% @doc Given an index, determine all sibling indices that participate in one
%%      or more preflists with the specified index.
-spec preflist_siblings(index()) -> [index()].
preflist_siblings(Index) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    preflist_siblings(Index, Ring).

%% @doc See {@link preflist_siblings/1}.
-spec preflist_siblings(index(), riak_core_ring()) -> [index()].
preflist_siblings(Index, Ring) ->
    MaxN = determine_max_n(Ring),
    preflist_siblings(Index, MaxN, Ring).

-spec determine_max_n(riak_core_ring()) -> pos_integer().
determine_max_n(Ring) ->
    lists:max(determine_all_n(Ring)).

-spec preflist_siblings(index(), pos_integer(), riak_core_ring()) -> [index()].
preflist_siblings(Index, N, Ring) ->
    IndexBin = <<Index:160/integer>>,
    PL = riak_core_ring:preflist(IndexBin, Ring),
    Indices = [Idx || {Idx, _} <- PL],
    RevIndices = lists:reverse(Indices),
    {Succ, _} = lists:split(N-1, Indices),
    {Pred, _} = lists:split(N-1, tl(RevIndices)),
    lists:reverse(Pred) ++ Succ.


%% ===================================================================
%% Preflist utility functions
%% ===================================================================

%% @doc Given a key, determine the associated preflist index_n.
-spec get_index_n(binary()) -> index_n().
get_index_n(BinBKey) ->
    % BucketProps = riak_core_bucket:get_bucket(Bucket),
    % N = proplists:get_value(n_val, BucketProps),
    N = ?N,
    ChashKey = riak_core_util:chash_key(BinBKey),
    {ok, CHBin} = riak_core_ring_manager:get_chash_bin(),
    Index = chashbin:responsible_index(ChashKey, CHBin),
    {Index, N}.