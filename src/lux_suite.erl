%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Copyright 2012-2015 Tail-f Systems AB
%%
%% See the file "LICENSE" for information on usage and redistribution
%% of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(lux_suite).

-export([run/2]).

-include("lux.hrl").
-include_lib("kernel/include/file.hrl").

-define(FF(Format, Args), lists:flatten(io_lib:format(Format, Args))).

-record(rstate,
        {files                      :: [string()],
         mode = execute             :: run_mode(),
         skip_skip = false          :: boolean(),
         progress = brief           :: silent | brief | doc | compact | verbose,
         config_dir                 :: string(),
         file_pattern = "^[^\\\.].*\\\.lux" ++ [$$] :: string(),
         case_prefix = ""           :: string(),
         log_fd                     :: file:io_device(),
         log_dir                    :: file:filename(),
         summary_log                :: string(),
         config_name                :: string(),
         config_file                :: string(),
         suite = "unknown"          :: string(),
         start_time                 :: {non_neg_integer(),
                                        non_neg_integer(),
                                        non_neg_integer()},
         run                        :: string(),
         extend_run = false         :: boolean(),
         revision = ""              :: string(),
         hostname = real_hostname() :: string(),
         rerun = disable            :: enable | success | skip | warning |
                                       fail | error | disable,
         html = enable              :: enable | success | skip | warning |
                                       fail | error | disable,
         warnings = []              :: [{warning, string(),
                                         string(), string()}],
         internal_opts = []         :: [{atom(), term()}], % Internal opts
         user_opts = []             :: [{atom(), term()}], % Command line opts
         file_opts = []             :: [{atom(), term()}], % Script opts
         config_opts = []           :: [{atom(), term()}], % Arch spec opts
         default_opts = []          :: [{atom(), term()}], % Default opts
         builtin_dict = lux_utils:builtin_dict()
                                    :: [string()], % ["name=val"]
         system_dict = lux_utils:system_dict()
                                    :: [string()], % ["name=val"]
         tap_opts = []              :: [string()],
         tap                        :: term() % #tap{}
        }).

run(Files, Opts) when is_list(Files) ->
    case parse_ropts(Opts, #rstate{files = Files}) of
        {ok, R} when R#rstate.mode =:= list;
                     R#rstate.mode =:= list_dir;
                     R#rstate.mode =:= doc ->
            LogDir = R#rstate.log_dir,
            LogBase = "lux_summary.log",
            R2 = compute_files(R, LogDir, LogBase),
            R3 = R2#rstate{log_fd = undefined, summary_log = undefined},
            {_ConfigData, R4} = parse_config(R3),
            {R5, Summary, Results} =
                run_suite(R4, R4#rstate.files, success, []),
            write_results(R5, Summary, Results);
        {ok, R} ->
            LogDir = R#rstate.log_dir,
            LogBase = "lux_summary.log",
            R2 = compute_files(R, LogDir, LogBase),
            SummaryLog = filename:join([LogDir, LogBase]),
            case ensure_log_dir(R2, SummaryLog) of
                {ok, R3} ->
                    do_run(R3, SummaryLog);
                {error, File, DirErr} ->
                    {error, File, DirErr}
            end;
        {error, {badarg, Name, Val}} ->
            ArgErr =
                lux_log:safe_format(undefined,
                                    "ERROR: ~p is an illegal argument (~p)\n",
                                    [Name, Val]),
            {error, hd(Files), ArgErr};
        {error, File, ArgErr} ->
            {error, File, ArgErr}
    end.

run_suite(R0, SuiteFiles, Summary, Results) ->
    Scripts = expand_suite(R0,  SuiteFiles, []),
    lux:trace_me(80, suite, string:join(SuiteFiles, " "), []),
    {ok, R} = tap_suite_begin(R0, Scripts, ""),
    try
        {NewR, NewSummary0, NewResults} =
            run_cases(R, Scripts, Summary, Results, 1, []),
        NewSummary =
            case NewResults of
                [] -> warning;
                _  -> NewSummary0
                end,
        lux:trace_me(80, suite, NewSummary, []),
        tap_suite_end(NewR, NewSummary, NewResults),
        {NewR, NewSummary, NewResults}
    catch Class:Reason ->
            lux:trace_me(80, suite, Class, [Reason]),
            if
                R#rstate.tap =/= undefined ->
                    lux_tap:bail_out(R#rstate.tap, "Internal error");
                true ->
                    ok
            end,
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    end.

expand_suite(R, [SuiteFile | SuiteFiles], Acc) ->
    case list_files(R, SuiteFile) of
        {ok, CaseFiles} ->
            Expanded = [{SuiteFile, {ok, CF}} || CF <- CaseFiles],
            expand_suite(R, SuiteFiles, [Expanded | Acc]);
        {error, Reason} ->
            expand_suite(R, SuiteFiles, [{SuiteFile, {error, Reason}} | Acc])
    end;
expand_suite(_R, [], Acc) ->
    lists:append(lists:reverse(Acc)).

list_files(R, File) ->
    case file:read_file_info(File) of
        {ok, #file_info{type = directory}} ->
            Fun = fun(F, Acc) -> [F | Acc] end,
            RegExp = R#rstate.file_pattern,
            Files = lux_utils:fold_files(File, RegExp, true, Fun, []),
            {ok, lists:sort(Files)};
        {ok, _} ->
            {ok, [File]};
        {error, Reason} ->
            {error, Reason}
    end.

do_run(#rstate{progress = Progress} = R, SummaryLog) ->
    Opts = [{case_prefix, R#rstate.case_prefix}],
    case lux_log:open_summary_log(Progress, SummaryLog, R#rstate.extend_run) of
        {ok, Exists, SummaryFd} ->
            TimerRef = start_suite_timer(R),
            try
                R2 = R#rstate{log_fd = SummaryFd, summary_log = SummaryLog},
                {ConfigData, R3} = parse_config(R2),
                HtmlPrio = lux_utils:summary_prio(R2#rstate.html),
                InitialSummary = success,
                SummaryPrio0 = lux_utils:summary_prio(InitialSummary),
                InitialRes =
                    case Exists of
                        true ->
                            TmpLog = SummaryLog ++ ".tmp",
                            case lux_log:parse_summary_log(TmpLog) of
                                {ok, _, Groups, _, _, _} ->
                                    initial_results(Groups);
                                {error, _, _} ->
                                    []
                            end;
                        false ->
                            LogDir = filename:dirname(SummaryLog),
                            ConfigLog = filename:join([LogDir,
                                                       "lux_config.log"]),
                            ok = lux_log:write_config_log(ConfigLog,ConfigData),
                            lux_log:write_results(R2#rstate.progress,
                                                  SummaryLog, skip, [], []),
                            %% Generate initial html log
                            if
                                SummaryPrio0 >= HtmlPrio,
                                R3#rstate.mode =/= list,
                                R3#rstate.mode =/= list_dir ->
                                    annotate_summary_log(R3, skip, []);
                                true ->
                                    ok
                            end,
                            []
                    end,
                {R5, Summary, Results} =
                    run_suite(R3, R3#rstate.files, InitialSummary, InitialRes),
                print_results(R5, Summary, Results),
                _ = write_results(R5, Summary, Results),
                lux_log:close_summary_log(SummaryFd, SummaryLog),
                SummaryPrio = lux_utils:summary_prio(Summary),
                if
                    SummaryPrio >= HtmlPrio,
                    R5#rstate.mode =/= list,
                    R5#rstate.mode =/= list_dir ->
                        case lux_html:annotate_log(false, SummaryLog, Opts) of
                            ok ->
                                case R5#rstate.progress of
                                    silent ->
                                        ok;
                                    _ ->
                                        io:format("\nfile://~s\n",
                                                  [SummaryLog ++ ".html"])
                                end,
                                {ok, Summary, SummaryLog, Results};
                            {error, _File, _ReasonStr} = Error ->
                                Error
                        end;
                    true ->
                        {ok, Summary, SummaryLog, Results}
                end
            catch
                throw:{error, File, ReasonStr} ->
                    lux_log:close_summary_tmp_log(SummaryFd),
                    {error, File, ReasonStr};
                Class:Reason ->
                    lux_log:close_summary_tmp_log(SummaryFd),
                    ReasonStr =
                        lists:flatten(io_lib:format("~p:~p ~p",
                                                    [Class,
                                                     Reason,
                                                     erlang:get_stacktrace()])),
                    {error, SummaryLog, ReasonStr}
            after
                cancel_timer(TimerRef)
            end;
        {error, FileReason} ->
            FileErr =
                lux_log:safe_format(undefined,
                                    "ERROR: Failed to open logfile:"
                                    " ~s -> ~s\n",
                                    [SummaryLog,
                                     file:format_error(FileReason)]),
            {error, SummaryLog, FileErr}
    end.


compute_files(R, _LogDir, _LogBase) when R#rstate.rerun =:= disable ->
    R;
compute_files(R, _LogDir, LogBase) when R#rstate.files =/= [] ->
    OldLogDirs = R#rstate.files,
    compute_files(R, OldLogDirs, LogBase, []);
compute_files(R, LogDir, LogBase) ->
    OldLogDirs = [filename:join([filename:dirname(LogDir), "latest_run"])],
    compute_files(R, OldLogDirs, LogBase, []).

compute_files(R, [LogDir|LogDirs], LogBase, Acc) ->
    OldLog = filename:join([LogDir, LogBase]),
    LatestRes =
        case lux_log:parse_summary_log(OldLog) of
            {ok, _, Groups, _, _, _} ->
                initial_results(Groups);
            {error, _, _} ->
                []
        end,
    Files = compute_files(R, LatestRes),
    compute_files(R, LogDirs, LogBase, Files ++ Acc);
compute_files(R, [], _LogBase, Acc) ->
    R#rstate{files = lists:usort(Acc)}.

compute_files(R, InitialRes) ->
    MinCond = lux_utils:summary_prio(R#rstate.rerun),
    Return = fun(Res, Script) ->
                     Cond = lux_utils:summary_prio(Res),
                     if
                         Cond >= MinCond ->
                             RelScript = lux_utils:drop_prefix(Script),
                             {true, binary_to_list(RelScript)};
                         true ->
                             false
                     end
             end,
    Filter =
        fun(Res) ->
                case Res of
                    {ok, ScriptRes, Script, _RawLineNo, _} ->
                        Return(ScriptRes, Script);
                    {error, Script, _RawLineNo, _Reason} ->
                        Return(error, Script)
                end
        end,
    lists:zf(Filter, InitialRes).

initial_results(Groups) ->
    Fun =
        fun(Script, {result, Res}) ->
                case Res of
                    success ->
                        {ok, Res, Script, "0", []};
                    skip ->
                        {ok, Res, Script, "0", []};
                    {error_line, RawLineNo, Reason} ->
                        {error, Script, RawLineNo, Reason};
                    {error, [Reason]} ->
                        case binary:split(Reason, <<": ">>, [global]) of
                            [_, <<"Syntax error at line ", N/binary>>, _] ->
                                {error, Script, binary_to_list(N), Reason};
                            _ ->
                                {error, Script, "0", Reason}
                        end;
                  {error, Reason} ->
                        {error, Script, "0", Reason};
                    {fail, _Script, RawLineNo, _Expected, _Actual, _Details} ->
                        {ok, fail, Script, binary_to_list(RawLineNo), []}
                end
        end,
    [Fun(Script, Res) ||
        {test_group, _Group, Cases} <- Groups,
        {test_case, Script, _Log, _Doc, _HtmlLog, Res} <- Cases].

parse_ropts([{Name, Val} = NameVal | T], R) ->
    case Name of
        %% suite options
        file_pattern when is_list(Val) ->
            parse_ropts(T, R#rstate{file_pattern = Val});
        case_prefix when is_list(Val) ->
            UserOpts = [NameVal | R#rstate.user_opts],
            parse_ropts(T, R#rstate{case_prefix = Val,
                                    user_opts = UserOpts});
        progress when Val =:= silent; Val =:= brief;
                      Val =:= doc; Val =:= compact;
                      Val =:= verbose ->
            UserOpts = [NameVal | R#rstate.user_opts],
            parse_ropts(T, R#rstate{progress = Val,
                                    user_opts = UserOpts});
        config_dir when is_list(Val) ->
            parse_ropts(T, R#rstate{config_dir = filename:absname(Val)});
        config_name when is_list(Val) ->
            parse_ropts(T, R#rstate{config_name = Val});
        suite when is_list(Val) ->
            parse_ropts(T, R#rstate{suite = Val});
        run when is_list(Val) ->
            parse_ropts(T, R#rstate{run = Val});
        extend_run when Val =:= true; Val =:= false ->
            parse_ropts(T, R#rstate{extend_run = Val});
        revision when is_list(Val) ->
            parse_ropts(T, R#rstate{revision = Val});
        hostname when is_list(Val) ->
            parse_ropts(T, R#rstate{hostname = Val});
        skip_skip when Val =:= true; Val =:= false ->
            parse_ropts(T, R#rstate{skip_skip = Val});
        mode when Val =:= list; Val =:= list_dir; Val =:= doc;
                  Val =:= validate; Val =:= execute ->
            parse_ropts(T, R#rstate{mode = Val});
        rerun when Val =:= enable; Val =:= success;
                   Val =:= skip; Val =:= warning;
                   Val =:= fail; Val =:= error;
                   Val =:= disable ->
            parse_ropts(T, R#rstate{rerun = Val});
        html when Val =:= enable; Val =:= success;
                  Val =:= skip; Val =:= warning;
                  Val =:= fail; Val =:= error;
                  Val =:= disable ->
            parse_ropts(T, R#rstate{html = Val});
        tap when is_list(Val) ->
            parse_ropts(T, R#rstate{tap_opts = [Val|R#rstate.tap_opts]});

        %% case options
        _ ->
            UserOpts = [NameVal | R#rstate.user_opts],
            parse_ropts(T, R#rstate{user_opts = UserOpts})
    end;
parse_ropts([], R) ->
    {ok, adjust_log_dir(R)}.

adjust_log_dir(R) ->
    Now = erlang:now(),
    UniqStr = uniq_str(Now),
    UniqRun = "run_" ++ UniqStr,
    Run =
        case R#rstate.run of
            undefined -> UniqRun;
            UserRun   -> UserRun
        end,
    UserLogDir = pick_val(log_dir, R, undefined),
    RelLogDir =
        case UserLogDir of
            undefined -> filename:join(["lux_logs", UniqRun]);
            LogDir    -> LogDir
        end,
    AbsLogDir0 = filename:absname(RelLogDir),
    AbsLogDir =
        if
            UserLogDir =:= undefined, R#rstate.extend_run ->
                ParentDir0 = filename:dirname(AbsLogDir0),
                Link0 = filename:join([ParentDir0, "latest_run"]),
                case file:read_link(Link0) of
                    {ok, LinkTo} ->
                        %% Reuse old log dir
                        filename:absname(filename:join([ParentDir0, LinkTo]));
                    {error, _} ->
                        AbsLogDir0
                end;
            true ->
                AbsLogDir0
        end,
    UserOpts = merge_opts([{log_dir, AbsLogDir}], R#rstate.user_opts),
    R#rstate{start_time = Now,
             run = Run,
             log_dir = AbsLogDir,
             user_opts = UserOpts}.

ensure_log_dir(#rstate{log_dir = AbsLogDir, extend_run = ExtendRun} = R,
               SummaryLog) ->
    case opt_ensure_dir(ExtendRun, SummaryLog) of
        ok ->
            ParentDir = filename:dirname(AbsLogDir),
            Link = filename:join([ParentDir, "latest_run"]),
            Base = filename:basename(AbsLogDir),
            _ = file:delete(Link),
            _ = file:make_symlink(Base, Link),

            RelFiles = R#rstate.files,
            AbsFiles = [filename:absname(F) || F <- RelFiles],
            TagFiles = [{config_dir, R#rstate.config_dir} |
                        [{file, F} || F <- RelFiles]],
            try
                lists:foreach(fun check_file/1, TagFiles),
                {ok, R#rstate{files = AbsFiles}}
            catch
                throw:{error, File, Reason} ->
                    {error, File, Reason}
            end;
        summary_log_exists ->
            {error,
             AbsLogDir,
             lux_log:safe_format(undefined,
                                 "ERROR: Summary log file already exists:"
                                 " ~s\n",
                                 [SummaryLog])};
        {error, FileReason} ->
            {error,
             AbsLogDir,
             lux_log:safe_format(undefined,
                                 "ERROR: Failed to create log directory:"
                                 " ~s -> ~s\n",
                                 [AbsLogDir, file:format_error(FileReason)])}
    end.

opt_ensure_dir(ExtendRun, SummaryLog) ->
    case not ExtendRun andalso filelib:is_dir(SummaryLog) of
        true  -> summary_log_exists;
        false -> filelib:ensure_dir(SummaryLog)
    end.

check_file({Tag, File}) ->
    case Tag of
        config_dir when File =:= undefined ->
            ok;
        config_dir ->
            case filelib:is_dir(File) of
                true ->
                    ok;
                false ->
                    BinErr =
                        lux_log:safe_format(undefined,
                                            "ERROR: ~p ~s: ~s \n",
                                            [Tag,
                                             File,
                                             file:format_error(enoent)]),
                    throw({error, File, BinErr})
            end;
        file ->
            case filelib:is_file(File) of
                true ->
                    ok;
                false ->
                    BinErr =
                        lux_log:safe_format(undefined,
                                            "ERROR: ~s: ~s \n",
                                            [File,
                                             file:format_error(enoent)]),
                    throw({error, File, BinErr})
            end
    end.

uniq_str(Now) ->
    {{Year, Month, Day}, {Hour, Min, Sec}} =
        calendar:now_to_datetime(Now),
    lists:concat([Year, "_", r2(Month), "_", r2(Day), "_",
                  r2(Hour), "_", r2(Min), "_", r2(Sec)]).

r2(Int) when is_integer(Int) ->
    r2(integer_to_list(Int));
r2(String) when is_list(String) ->
    string:right(String, 2, $0).

run_cases(R, [{_SuiteFile,{error,_Reason}}|Scripts],
          OldSummary, Results, CC, List)
  when R#rstate.mode =:= list; R#rstate.mode =:= list_dir ->
    run_cases(R, Scripts, OldSummary, Results, CC+1, List);
run_cases(R, [{SuiteFile, {error,Reason}}|Scripts],
          OldSummary, Results, CC, List) ->
    RelSuiteFile = rel_script(R, SuiteFile),
    init_case_rlog(R, RelSuiteFile, SuiteFile),
    ListErr =
        double_rlog(R, "~s~s: ~s\n",
                    [?TAG("error"), SuiteFile, file:format_error(Reason)]),
    Results2 = [{error, SuiteFile, ListErr} | Results],
    lux:trace_me(70, suite, 'case', SuiteFile, []),
    tap_case_begin(R, SuiteFile),
    lux:trace_me(70, 'case', suite, error, [Reason]),
    tap_case_end(R, CC, SuiteFile, error, "0", Reason, Reason),
    run_cases(R, Scripts, OldSummary, Results2, CC+1, List);
run_cases(R, [{SuiteFile,{ok,Script}} | Scripts],
          OldSummary, Results, CC, List) ->
    RelScript = rel_script(R, Script),
    RunMode = R#rstate.mode,
    case parse_script(R#rstate{warnings = []}, SuiteFile, Script) of
        {ok, R2, Script2, Cmds, Opts} ->
            NewWarnings = R2#rstate.warnings,
            AllWarnings = R#rstate.warnings ++ NewWarnings,
            case RunMode of
                list ->
                    run_cases(R2, Scripts, OldSummary, Results,
                              CC+1, [Script|List]);
                list_dir ->
                    run_cases(R2, Scripts, OldSummary, Results,
                              CC+1, [Script|List]);
                doc ->
                    Docs = extract_doc(Script2, Cmds),
                    io:format("~s:\n",
                              [lux_utils:drop_prefix(Script2)]),
                    [io:format("~s~s\n", [lists:duplicate(Level, $\t), Str]) ||
                        #cmd{arg = {Level, Str}} <- Docs],
                    case NewWarnings of
                        [] ->
                            NewSummary = OldSummary,
                            Results2 = Results;
                        _ ->
                            Summary = warning,
                            NewSummary = lux_utils:summary(OldSummary, Summary),
                            Results2 = [{Summary, Script2, NewWarnings} |
                                        Results]
                    end,
                    run_cases(R#rstate{warnings = AllWarnings},
                              Scripts, NewSummary, Results2, CC+1, List);
                validate ->
                    init_case_rlog(R2, RelScript, Script),
                    case NewWarnings of
                        [] ->
                            Summary = success,
                            NewSummary = OldSummary,
                            Results2 = Results;
                        _ ->
                            Summary = warning,
                            NewSummary = lux_utils:summary(OldSummary, Summary),
                            Results2 = [{NewSummary, Script2, NewWarnings} |
                                        Results]
                    end,
                    double_rlog(R2, "~s~s\n",
                                [?TAG("result"),
                                 string:to_upper(atom_to_list(Summary))]),
                    run_cases(R#rstate{warnings = AllWarnings},
                              Scripts, NewSummary, Results2, CC+1, List);
                execute ->
                    lux:trace_me(70, suite, 'case', RelScript, []),
                    tap_case_begin(R, Script),
                    init_case_rlog(R2, RelScript, Script),
                    Res = lux:interpret_commands(Script2, Cmds, Opts),
                    SkipReason = "",
                    case Res of
                        {ok, Summary, _, FullLineNo, CaseLogDir,
                         Events, FailBin} ->
                            lux:trace_me(70, 'case', suite, Summary,
                                  []),
                            tap_case_end(R2, CC, Script, Summary,
                                         FullLineNo, SkipReason, FailBin),
                            NewSummary = lux_utils:summary(OldSummary, Summary),
                            Res2 = {ok, Summary, Script, FullLineNo,
                                    CaseLogDir, Events, FailBin},
                            NewResults = [Res2 | Results],
                            NewScripts = Scripts;
                        {error, _, FullLineNo, CaseLogDir, ErrorMsg}
                          when ErrorMsg =:= <<"suite_timeout" >> ->
                            Summary = error,
                            lux:trace_me(70, 'case', suite, Summary,
                                         [FullLineNo]),
                            tap_case_end(R2, CC, Script, Summary,
                                         FullLineNo, SkipReason, ErrorMsg),
                            NewSummary = lux_utils:summary(OldSummary, Summary),
                            NewResults = [Res | Results],
                            NewScripts = [];
                        {error, _, FullLineNo, CaseLogDir, ErrorMsg} ->
                            Summary = error,
                            lux:trace_me(70, 'case', suite, Summary,
                                         [FullLineNo]),
                            tap_case_end(R2, CC, Script, Summary,
                                         FullLineNo, SkipReason, ErrorMsg),
                            NewSummary = lux_utils:summary(OldSummary, Summary),
                            NewResults = [Res | Results],
                            NewScripts = Scripts
                    end,
                    HtmlPrio = lux_utils:summary_prio(R2#rstate.html),
                    SummaryPrio = lux_utils:summary_prio(NewSummary),
                    R3 = R2#rstate{warnings = AllWarnings},
                    if
                        SummaryPrio >= HtmlPrio ->
                            Base = filename:basename(Script),
                            EventLog = filename:join([CaseLogDir,
                                                      Base ++ ".event.log"]),
                            lux_html:annotate_log(false, EventLog, Opts),
                            annotate_summary_log(R3, NewSummary, NewResults);
                        true ->
                            ignore
                    end,
                    run_cases(R3, NewScripts, NewSummary, NewResults,
                              CC+1, List)
            end;
        {skip, R2, _ErrorStack, _SkipReason}
          when RunMode =:= list; RunMode =:= list_dir ->
            run_cases(R2, Scripts, OldSummary, Results, CC+1, List);
        {skip, R2, ErrorStack, SkipReason} ->
            {Script2, _, _} = lists:last(ErrorStack),
            lux:trace_me(70, suite, 'case', RelScript, []),
            tap_case_begin(R, Script),
            init_case_rlog(R2, RelScript, Script),
            double_rlog(R2, "~s~s\n",
                        [?TAG("result"), SkipReason]),
            Summary =
                case binary_to_list(SkipReason) of
                    "FAIL" ++ _ -> fail;
                    _           -> skip
                end,
            lux:trace_me(70, 'case', suite, Summary, [SkipReason]),
            tap_case_end(R, CC, Script, Summary,
                         "0", binary_to_list(SkipReason), <<>>),
            NewSummary = lux_utils:summary(OldSummary, Summary),
            Res = {ok, Summary, Script2, "0", R2#rstate.log_dir, [], <<>>},
            Results2 = [Res | Results],
            NewWarnings = R2#rstate.warnings,
            AllWarnings = R#rstate.warnings ++ NewWarnings,
            run_cases(R2#rstate{warnings = AllWarnings},
                      Scripts, NewSummary, Results2, CC+1, List);
        {error, _R2, _ErrorStack, _ErrorBin}
          when RunMode =:= list; RunMode =:= list_dir ->
            run_cases(R, Scripts, OldSummary, Results, CC+1, [Script|List]);
        {error, _R2, ErrorStack, ErrorBin} when RunMode =:= doc ->
            {MainFile, _FullLineNo, ErrorBin2} =
                parse_error(ErrorStack, ErrorBin),
            io:format("~s:\n\tERROR: ~s: ~s\n",
                      [Script, MainFile, ErrorBin2]),
            run_cases(R, Scripts, OldSummary, Results, CC+1, List);
        {error, R2, ErrorStack, ErrorBin} ->
            {MainFile, FullLineNo, ErrorBin2} =
                parse_error(ErrorStack, ErrorBin),
            init_case_rlog(R2, RelScript, Script),
            double_rlog(R2, "~sERROR ~s: ~s\n",
                        [?TAG("result"), MainFile, ErrorBin2]),
            Summary = error,
            tap_case_begin(R2, Script),
            lux:trace_me(70, 'case', suite, Summary, []),
            tap_case_end(R2, CC, Script, Summary,
                         "0", ErrorBin, ErrorBin),
            NewWarnings = R2#rstate.warnings,
            AllWarnings = R#rstate.warnings ++ NewWarnings,
            NewSummary = lux_utils:summary(OldSummary, Summary),
            Results2 = [{error, MainFile, FullLineNo, ErrorBin2} | Results],
            run_cases(R#rstate{warnings = AllWarnings},
                      Scripts, NewSummary, Results2, CC+1, List)
    end;
run_cases(R, [], Summary, Results, _CC, List) ->
    List2 = [lux_utils:drop_prefix(File) || File <- List],
    case R#rstate.mode of
        list ->
            [io:format("~s\n", [File]) ||
                File <- lists:usort(List2)];
        list_dir ->
            List3 = [filename:dirname(File) || File <- List2],
            [io:format("~s\n", [File]) ||
                File <- lists:usort(List3)];
        _ ->
            ok
    end,
    {R, Summary, lists:reverse(Results)}.

annotate_summary_log(R, NewSummary, NewResults) ->
    file:sync(R#rstate.log_fd), % Flush summary log
    _ = write_results(R, NewSummary, NewResults),
    SummaryLog = R#rstate.summary_log,
    TmpLog = SummaryLog ++ ".tmp",
    Opts = [{case_prefix, R#rstate.case_prefix}],
    lux_html:annotate_log(false, TmpLog, Opts),
    file:rename(TmpLog++".html",SummaryLog++".html").

extract_doc(File, Cmds) ->
    Fun = fun(Cmd, _RevFile, _CmdStack, Acc) ->
                  case Cmd of
                      #cmd{type = doc} ->
                          [Cmd | Acc];
                      _ ->
                          Acc
                  end
          end,
    lists:reverse(lux_utils:foldl_cmds(Fun, [], File, [], Cmds)).

write_results(#rstate{mode=Mode, summary_log=SummaryLog},
              Summary, Results)
  when Mode =:= list; Mode =:= list_dir; Mode =:= doc ->
    {ok, Summary, SummaryLog, Results};
write_results(#rstate{progress=Progress,
                      summary_log=SummaryLog,
                      warnings=Warnings},
              Summary, Results) when is_list(SummaryLog) ->
    lux_log:write_results(Progress, SummaryLog, Summary, Results, Warnings),
    {ok, Summary, SummaryLog, Results}.

print_results(#rstate{progress=Progress,warnings=Warnings}, Summary, Results) ->
    lux_log:print_results(Progress, {false,standard_io},
                          Summary, Results, Warnings).

parse_script(R, SuiteFile, Script) ->
    Opts0 = config_opts(R),
    case lux:parse_file(Script, R#rstate.mode, R#rstate.skip_skip, Opts0) of
        {ok, Script2, Cmds, FileOpts} ->
            FileOpts2 = merge_opts(FileOpts, R#rstate.file_opts),
            R2 = R#rstate{internal_opts = [],
                          file_opts = FileOpts2},
            LogDir = log_dir(R2, SuiteFile, Script2),
            LogFd = R#rstate.log_fd,
            LogFun = fun(Bin) -> lux_log:safe_write(LogFd, Bin) end,
            InternalOpts = [{log_dir, LogDir},
                            {log_fun, LogFun},
                            {log_fd,  LogFd}],
            UserOpts = R2#rstate.user_opts,
            Opts = lists:foldl(fun(New, Acc) -> merge_opts(New, Acc) end,
                               [],
                               [
                                R2#rstate.default_opts,
                                R2#rstate.config_opts,
                                FileOpts2,
                                UserOpts,
                                InternalOpts
                               ]),
            R3 = R2#rstate{user_opts = UserOpts,
                           file_opts = FileOpts2,
                           internal_opts = InternalOpts},
            {ok, R3, Script2, Cmds, Opts};
        {skip, ErrorStack, ErrorBin} ->
            {skip, R, ErrorStack, ErrorBin};
        {error, ErrorStack, ErrorBin} ->
            {error, R, ErrorStack, ErrorBin}
    end.

parse_config(R) ->
    %% Default opts
    DefaultBase = "luxcfg",
    DefaultDir = filename:absname(code:lib_dir(?APPLICATION, priv)),
    DefaultFile = filename:join([DefaultDir, DefaultBase]),
    DefaultOpts = parse_config_file(R, DefaultFile),
    R2 = R#rstate{default_opts = DefaultOpts},

    %% Config dir
    case pick_val(config_dir, R2, R#rstate.config_dir) of
        undefined -> ConfigDir = code:lib_dir(?APPLICATION, priv);
        ConfigDir -> ok
    end,
    check_file({config_dir, ConfigDir}),

    %% Arch spec opts
    ActualConfigName = config_name(),
    {ConfigName, ConfigFile} =
        config_file(R2, ConfigDir, R2#rstate.config_name, ActualConfigName),
    ConfigOpts = parse_config_file(R2, ConfigFile),
    R3 = R2#rstate{config_name = ConfigName,
                   config_dir = ConfigDir,
                   config_file = ConfigFile,
                   config_opts = ConfigOpts},
    ConfigData =
        builtins(R, ActualConfigName) ++
        [{'default file', [string], DefaultFile}] ++ DefaultOpts ++
        [{'config file', [string], ConfigFile}] ++ ConfigOpts,
    {ConfigData, R3}.

builtins(R, ActualConfigName) ->
    {ok, Cwd} = file:get_cwd(),
    [
     {'start time', [string], lux_utils:now_to_string(R#rstate.start_time)},
     {hostname, [string], R#rstate.hostname},
     {architecture, [string], ActualConfigName},
     {'system info', [string], sys_info()},
     {suite, [string], R#rstate.suite},
     {run, [string], R#rstate.run},
     {revision, [string], R#rstate.revision},
     {run_dir, [string], Cwd},
     {'config name', [string], R#rstate.config_name},
     {config_dir, [string], R#rstate.config_dir}
    ].

config_name() ->
    case string:tokens(os:cmd("uname -sm; echo $?"), "\n ") of
        [Kernel, Machine, CmdStatus] when CmdStatus =:= "0" ->
            Kernel ++ "-" ++ Machine;
        _Bad ->
            erlang:system_info(system_architecture)
    end.

parse_config_file(R, ConfigFile) ->
    Opts0 = config_opts(R),
    case lux:parse_file(ConfigFile, R#rstate.mode, false, Opts0) of
        {ok, _File, _Cmds, Opts} ->
            Key = config_dir,
            Opts2 =
                case lists:keyfind(Key, 1, Opts) of
                    false ->
                        Opts;
                    {_, Dir} ->
                        Top = filename:dirname(ConfigFile),
                        Dir2 = filename:absname(Dir, Top),
                        lists:keystore(Key, 1, Opts, {Key, Dir2})
                end,
            lists:keydelete(log_dir, 1, Opts2);
        {error, ErrorStack, ErrorBin} ->
            Enoent = list_to_binary(file:format_error(enoent)),
            if
                ErrorBin =:= Enoent ->
                    ok;
                true ->
                    {MainFile, FullLineNo, ErrorBin2} =
                        parse_error(ErrorStack, ErrorBin),
                    double_rlog(R, "~s~s: ~s: ~s\n",
                                [?TAG("error"), MainFile,
                                 ErrorBin2, FullLineNo])
            end,
            []
    end.

config_opts(R) ->
    lists:append(lists:reverse(opts_dicts(R))).

parse_error(ErrorStack, ErrorBin) ->
    {MainFile, _, _} = hd(ErrorStack),
    {ErrorFile, _, _} = lists:last(ErrorStack),
    FullLineNo = lux_utils:pretty_full_lineno(ErrorStack),
    if
        ErrorFile =:= MainFile ->
            {MainFile, FullLineNo, ErrorBin};
        true ->
            FileBin = list_to_binary(ErrorFile),
            ErrorBin2 = <<FileBin/binary, ": ", ErrorBin/binary>>,
            {MainFile, FullLineNo, ErrorBin2}
    end.

config_file(R, ConfigDir, UserConfigName, ActualConfigName) ->
    Ext = ".luxcfg",
    case UserConfigName of
        undefined ->
            Host = R#rstate.hostname,
            HostFile = filename:join([ConfigDir, Host ++ Ext]),
            case filelib:is_regular(HostFile) of
                true  -> {Host, HostFile};
                false -> config_file2(ConfigDir, ActualConfigName, Ext)
            end;
        _ ->
            config_file2(ConfigDir, UserConfigName, Ext)
    end.

config_file2(ConfigDir, ConfigName, Ext) ->
    File = filename:join([ConfigDir, ConfigName ++ Ext]),
    case filelib:is_regular(File) of
        true ->
            {ConfigName, File};
        false ->
            DefaultFile = filename:join([ConfigDir, "luxcfg"]),
            {ConfigName, DefaultFile}
    end.

sys_info() ->
    lux_utils:chop_newline(os:cmd("uname -a")).

real_hostname() ->
    case inet:gethostname() of
        {ok, Host} -> Host;
        _          -> "localhost"
    end.

log_dir(R, SuiteFile, Script) ->
    LogDir = pick_val(log_dir, R, undefined),
    case Script =:= SuiteFile of
        true ->
            LogDir;
        false ->
            Suffix = lux_utils:drop_prefix(SuiteFile, Script),
            case filename:dirname(Suffix) of
                "."    -> LogDir;
                SubDir -> filename:join([LogDir, SubDir])
            end
    end.

double_rlog(#rstate{progress = Progress, log_fd = Fd}, Format, Args) ->
    IoList = io_lib:format(Format, Args),
    case Fd of
        undefined -> list_to_binary(IoList);
        _         -> lux_log:double_write(Progress, Fd, IoList)
    end.

init_case_rlog(#rstate{progress = Progress, log_fd = Fd},
               RelScript, AbsScript) ->
    Tag = ?TAG("test case"),
    AbsIoList = io_lib:format("\n~s~s\n", [Tag, AbsScript]),
    case Fd of
        undefined ->
            list_to_binary(AbsIoList);
        _ ->
            AbsBin = lux_log:safe_write(Fd, AbsIoList),
            case Progress of
                silent ->
                    ok;
                _ ->
                    RelIoList = io_lib:format("\n~s~s\n", [Tag, RelScript]),
                    lux_log:safe_write(undefined, list_to_binary(RelIoList))
            end,
            AbsBin
    end.

rel_script(R, AbsScript) ->
    RelScript = lux_utils:drop_prefix(AbsScript),
    R#rstate.case_prefix ++ RelScript.

start_suite_timer(R) ->
    SuiteTimeout = pick_val(suite_timeout, R, infinity),
    Msg = {suite_timeout, SuiteTimeout},
    Multiplier = pick_val(multiplier, R, 1000),
    case lux_utils:multiply(SuiteTimeout, Multiplier) of
        infinity   -> {infinity, Msg};
        NewTimeout -> {erlang:send_after(NewTimeout, self(), Msg), Msg}
    end.

cancel_timer({Ref, Msg}) ->
    case Ref of
        infinity ->
            ok;
        _ ->
            case erlang:cancel_timer(Ref) of
                false ->
                    receive
                        Msg -> ok
                    after 0 ->
                            ok
                    end;
                TimeLeft when is_integer(TimeLeft) ->
                    ok
            end
    end.

pick_val(Tag, R, Default) ->
    Dicts = opts_dicts(R),
    multi_key_find(Tag, 1, Dicts, Default).

multi_key_find(Tag, Pos, [Dict|Dicts], Default) ->
    case lists:keyfind(Tag, 1, Dict) of
        false ->
            multi_key_find(Tag, Pos, Dicts, Default);
        {_, Val} ->
            Val
    end;
multi_key_find(_Tag, _Pos, [], Default) ->
    Default.

opts_dicts(#rstate{internal_opts = I,
                   user_opts = U,
                   file_opts = F,
                   config_opts = C,
                   default_opts = D}) ->
    [I, U, F, C, D].

merge_opts(KeyVals, Acc) ->
    merge_opts(KeyVals, Acc, []).

merge_opts([{Key, Val} | KeyVals] = AllKeyVals, Acc, Updated) ->
    case lists:keyfind(Key, 1, Acc) of
        false -> OldVal = [];
        {_, OldVal} -> ok
    end,
    Updated2 = [Key | Updated],
    case merge_oper(Key, Updated) of
        reset ->
            %% Multi - Clear old settings in order to override unwanted defaults
            Stripped = [{K,V} || {K,V} <- Acc, K =/= Key],
            merge_opts(AllKeyVals, Stripped, Updated2);
        append ->
            %% Multi - Append new val
            Val2 = OldVal ++ Val,
            Acc2 = lists:keystore(Key, 1, Acc, {Key, Val2}),
            merge_opts(KeyVals, Acc2, Updated2);
        env ->
            %% Multi - handle settings with KEY=VAL syntax
            Val2 = merge_env_opt(Val, OldVal),
            Acc2 = lists:keystore(Key, 1, Acc, {Key, Val2}),
            merge_opts(KeyVals, Acc2, Updated2);
        replace ->
            %% Single - replace old val
            Acc2 = lists:keystore(Key, 1, Acc, {Key, Val}),
            merge_opts(KeyVals, Acc2, Updated2)
    end;
merge_opts([], Acc, _) ->
    Acc.

merge_oper(Key, Updated) ->
    case lux_interpret:config_type(Key) of
        {ok, _Pos, [{env_list, _}]} ->
            env;
        {ok, _Pos, [{reset_list, _}]} ->
            case lists:member(Key, Updated) of
                true  -> append;
                false -> reset
            end;
        {ok, _Pos, _} ->
            replace
    end.

merge_env_opt(Val, OldVal) ->
    New = [list_to_tuple(string:tokens(V, "=")) || V <- lists:reverse(Val)],
    Old = [list_to_tuple(string:tokens(V, "=")) || V <- OldVal],
    Insert = fun(Tuple, Acc) ->
                     SubKey = element(1, Tuple),
                     lists:keystore(SubKey, 1, Acc, Tuple)
             end,
    Merged = lists:foldl(Insert, Old, New),
    [string:join(tuple_to_list(T), "=") || T <- lists:keysort(1, Merged)].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

tap_suite_begin(R, Scripts, Directive)
  when R#rstate.mode =/= list,
       R#rstate.mode =/= list_dir,
       R#rstate.mode =/= doc ->
    TapLog = filename:join([R#rstate.log_dir, "lux.tap"]),
    TapOpts = [TapLog | R#rstate.tap_opts],
    case lux_tap:open(TapOpts) of
        {ok, TAP} ->
            ok = lux_tap:plan(TAP, length(Scripts), Directive),
            ok = lux_tap:diag(TAP, "\n"),
            %% ok = lux_tap:diag(TAP, "LUX - LUcid eXpect scripting"),
            Host = real_hostname(),
            ok = lux_tap:diag(TAP, "ssh " ++ Host),
            {ok, Cwd} = file:get_cwd(),
            ok = lux_tap:diag(TAP, "cd " ++ Cwd),
            RelFiles = [lux_utils:drop_prefix(F) || F <- R#rstate.files],
            ok = lux_tap:diag(TAP, "lux -t " ++ string:join(RelFiles, " ")),
            SummaryLog = lux_utils:drop_prefix(R#rstate.summary_log),
            ok = lux_tap:diag(TAP, "open " ++ SummaryLog ++ ".html"),
            ok = lux_tap:diag(TAP, "\n"),
            {ok, R#rstate{tap = TAP, tap_opts = TapOpts}};
        {error, Reason} ->
            {error, Reason}
    end;
tap_suite_begin(R, _Scripts, _Directive) ->
    {ok, R#rstate{tap = undefined}}.

tap_suite_end(#rstate{tap = TAP, warnings = Warnings}, Summary, Results)
  when TAP =/= undefined ->
    Len = fun(Res, Tag) ->
                  integer_to_list(length(lux_log:pick_result(Res, Tag)))
          end,
    ok = lux_tap:diag(TAP, "\n"),
    lux_tap:diag(TAP, ["Errors:     ", Len(Results, error)]),
    lux_tap:diag(TAP, ["Failed:     ", Len(Results, fail)]),
    lux_tap:diag(TAP, ["Warnings:   ", Len(Warnings, warning)]),
    lux_tap:diag(TAP, ["Skipped:    ", Len(Results, skip)]),
    lux_tap:diag(TAP, ["Successful: ", Len(Results, success)]),
    lux_tap:diag(TAP, ["Summary:    ", atom_to_list(Summary)]),
    lux_tap:close(TAP);
tap_suite_end(_R, _Summary, _Results) ->
    ok.

%% tap_case_begin(#rstate{tap = TAP} = R, AbsScript)
%%   when TAP =/= undefined ->
%%     RelScript = rel_script(R, AbsScript),
%%     ok = lux_tap:diag(TAP, "lux " ++ RelScript);
tap_case_begin(#rstate{}, _AbsScript) ->
    ok.

tap_case_end(#rstate{tap = TAP, skip_skip = SkipSkip} = R,
             CaseCount, AbsScript, Result, FullLineNo, Reason, Details)
  when TAP =/= undefined ->
    RelScript = rel_script(R, AbsScript),
    Descr = lists:concat([CaseCount, " ", RelScript]),
    TodoReason =
        case Reason of
            "" -> "";
            _  -> "TODO - " ++ Reason
        end,
    {Outcome, Directive} =
        case Result of
            error                 -> {not_ok, ""};
            fail when SkipSkip    -> {not_ok, TodoReason};
            fail                  -> {not_ok, ""};
            skip                  -> {ok,     Reason};
            success when SkipSkip -> {ok,     TodoReason};
            success               -> {ok,     ""}
        end,
    lux_tap:test(TAP, Outcome, "    " ++ Descr, Directive),
    case Details of
        <<>> ->
            ok;
        _ ->
            Prefix = string:to_upper(atom_to_list(Result)),
            Lines = [
                     iolist_to_binary([Prefix, " at line ", FullLineNo]) |
                     binary:split(Details, <<"\n">>, [global])
                    ],
            [ok = lux_tap:diag(TAP, binary_to_list(F)) || F <- Lines]
    end;
tap_case_end(#rstate{}, _CaseCount, _Script, _Result, _FullLineNo,
             _Reason, _Details) ->
    ok.
