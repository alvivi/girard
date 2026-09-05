%% Profile girard's inference over one package's modules, staged from the sweep
%% cache, using eprof (per-function time) or fprof (call-graph time).
%%
%%   erl -noshell -pa build/dev/erlang/*/ebin -s girard_prof main \
%%       <eprof|fprof> <packages-root> <package> -s init stop
%%
%% Uses the same staged source corpus and resolver as dev/girard/bench.gleam.
%% Unlike the benchmark it uses the default Erlang target and does not share an
%% interface cache between modules, so compare call shapes rather than timings.
-module(girard_prof).
-export([main/1, run/2]).

main([Mode, Root, Pkg]) ->
    Opts = options(Root),
    Files = gleam_sources(filename:join([Root, Pkg, "src"])),
    io:format("profiling ~s: ~p modules~n", [Pkg, length(Files)]),
    Loop = fun() -> annotate_all(Files, Opts) end,
    case Mode of
        "eprof" ->
            eprof:profile(Loop),
            eprof:stop_profiling(),
            eprof:analyze(total),
            eprof:stop();
        "fprof" ->
            fprof:apply(girard_prof, run, [Files, Opts]),
            fprof:profile(),
            fprof:analyse([{sort, acc}, {dest, "/tmp/girard_fprof.txt"}]),
            io:format("fprof analysis -> /tmp/girard_fprof.txt~n", [])
    end,
    erlang:halt(0).

run(Files, Opts) -> annotate_all(Files, Opts).

annotate_all(Files, Opts) ->
    lists:foldl(fun(F, {Ok, Err, Exprs}) ->
        case file:read_file(F) of
            {ok, Bin} ->
                case girard:annotate(Bin, Opts) of
                    {ok, Annotated} ->
                        %% AnnotatedModule(functions, constants, expressions, resolutions)
                        Es = element(4, Annotated),
                        {Ok + 1, Err, Exprs + length(Es)};
                    {error, _} ->
                        {Ok, Err + 1, Exprs}
                end;
            _ -> {Ok, Err, Exprs}
        end
    end, {0, 0, 0}, Files).

options(Root) ->
    Resolver = fun(Path) -> resolve(Root, Path) end,
    O0 = girard:default_options(),
    girard:with_resolver(O0, Resolver).

%% Read <Root>/<pkg>/src/<Path>.gleam for the first <pkg> that has it.
resolve(Root, Path) ->
    case file:list_dir(Root) of
        {ok, Pkgs} ->
            Candidates = [filename:join([Root, P, "src", binary_to_list(Path) ++ ".gleam"]) || P <- Pkgs],
            first_readable(Candidates);
        _ -> {error, nil}
    end.

first_readable([]) -> {error, nil};
first_readable([P | Rest]) ->
    case file:read_file(P) of
        {ok, Bin} -> {ok, Bin};
        _ -> first_readable(Rest)
    end.

gleam_sources(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            lists:flatmap(fun(E) ->
                P = filename:join(Dir, E),
                case filelib:is_dir(P) of
                    true -> gleam_sources(P);
                    false ->
                        case lists:suffix(".gleam", P) of
                            true -> [P];
                            false -> []
                        end
                end
            end, Entries);
        _ -> []
    end.
