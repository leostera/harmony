-module(text).
-export([shout/1, sum_to/1]).

%% Upper-cases ASCII letters and adds a "!". Recursive, so text:upcase/2 is
%% hashed as a recursive group.
shout(Input) when is_binary(Input) -> <<(upcase(Input, <<>>))/binary, "!">>.

upcase(<<C, Rest/binary>>, Acc) when C >= $a, C =< $z -> upcase(Rest, <<Acc/binary, (C - 32)>>);
upcase(<<C, Rest/binary>>, Acc) -> upcase(Rest, <<Acc/binary, C>>);
upcase(<<>>, Acc) -> Acc.

%% Calls OTP's lists module, which Harmony hashes along with this code.
sum_to(N) -> lists:sum(lists:seq(1, N)).
