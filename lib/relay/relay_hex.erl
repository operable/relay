-module(relay_hex).

-export([to_string/1,
         to_binary/1]).

to_string(Bin) ->
  list_to_binary(lists:flatten([io_lib:format("~2.16.0B", [X]) ||
                                 X <- binary_to_list(Bin)])).

to_binary(S) when is_binary(S) ->
  to_binary(binary_to_list(S));
to_binary(S) when is_list(S) ->
  to_binary(S, []).

to_binary([], Acc) ->
  list_to_binary(lists:reverse(Acc));
to_binary([X,Y|T], Acc) ->
  {ok, [V], []} = io_lib:fread("~16u", [X,Y]),
  to_binary(T, [V | Acc]).
