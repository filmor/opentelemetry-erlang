-module(otel_metrics_SUITE).

-compile(export_all).

-include_lib("stdlib/include/assert.hrl").
-include_lib("common_test/include/ct.hrl").

-include("otel_test_utils.hrl").
-include_lib("opentelemetry_api_experimental/include/otel_metrics.hrl").
-include_lib("opentelemetry_api_experimental/include/otel_meter.hrl").
-include("otel_view.hrl").
-include("otel_metrics.hrl").

-define(assertSumReceive(Name, Description, Unit, Datapoints),
        (fun() ->
                 receive
                     {otel_metric, #metric{name=MetricName,
                                           description=MetricDescription,
                                           unit=MetricUnit,
                                           data=#sum{datapoints=MetricDatapoints}}}
                       when MetricName =:= Name ->
                         ?assertEqual(Description, MetricDescription),
                         ?assertEqual(Unit, MetricUnit),
                         ?assertEqual(Description, MetricDescription),

                         SortedDatapoints =
                             lists:sort([{MetricValue, MetricAttributes} ||
                                            #datapoint{value=MetricValue,
                                                       attributes=MetricAttributes,
                                                       start_time_unix_nano=StartTimeUnixNano,
                                                       time_unix_nano=TimeUnixNano} <- MetricDatapoints, StartTimeUnixNano =< TimeUnixNano]),
                         ?assertMatch([], lists:sort(Datapoints) -- SortedDatapoints, SortedDatapoints)
                 after
                     5000 ->
                         ct:fail({metric_receive_timeout, ?LINE})
                 end
         end)()).

-define(assertLastValueReceive(Name, Description, Unit, Datapoints),
        (fun() ->
                 receive
                     {otel_metric, #metric{name=MetricName,
                                           description=MetricDescription,
                                           unit=MetricUnit,
                                           data=#gauge{datapoints=MetricDatapoints}}}
                       when MetricName =:= Name ->
                         ?assertEqual(Description, MetricDescription),
                         ?assertEqual(Unit, MetricUnit),
                         ?assertEqual(Description, MetricDescription),

                         SortedDatapoints =
                             lists:sort([{MetricValue, MetricAttributes} ||
                                            #datapoint{value=MetricValue,
                                                       attributes=MetricAttributes,
                                                       start_time_unix_nano=StartTimeUnixNano,
                                                       time_unix_nano=TimeUnixNano} <- MetricDatapoints, StartTimeUnixNano =< TimeUnixNano]),
                         ?assertMatch([], lists:sort(Datapoints) -- SortedDatapoints, SortedDatapoints)
                 after
                     5000 ->
                         ct:fail({metric_receive_timeout, ?LINE})
                 end
         end)()).

-define(assertNotReceive(Name, Description, Unit),
        (fun() ->
                 receive
                     {otel_metric, M=#metric{name=MetricName,
                                             description=MetricDescription,
                                             unit=MetricUnit}}
                       when MetricName =:= Name,
                            MetricDescription =:= Description,
                            MetricUnit =:= Unit ->
                         ct:fail({metric_received, M})
                 after
                     50 ->
                         ok
                 end
         end)()).

all() ->
    [default_view, provider_test, view_creation_test, wildcard_view, counter_add, multiple_readers,
     explicit_histograms, delta_explicit_histograms, delta_counter, cumulative_counter,
     kill_reader, kill_server, observable_counter, observable_updown_counter, observable_gauge,
     multi_instrument_callback, using_macros, float_counter, float_updown_counter, float_histogram,
     sync_filtered_attributes, async_filtered_attributes, delta_observable_counter,
     bad_observable_return, default_resource, histogram_aggregation_options, advisory_params
    ].

init_per_suite(Config) ->
    application:load(opentelemetry_experimental),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(provider_test, Config) ->
    application:load(opentelemetry_experimental),
    ok = application:set_env(opentelemetry_experimental, readers,
                             [#{module => otel_metric_reader,
                                config => #{exporter => {otel_metric_exporter_pid, self()},
                                            default_temporality_mapping => default_temporality_mapping()}}]),
    ok = application:set_env(opentelemetry_experimental, views,
                             [#{selector => #{instrument_name => a_counter},
                                aggregation_module => otel_aggregation_sum},
                              #{name => view_a,
                                selector => #{instrument_name => a_counter},
                                aggregation_module => otel_aggregation_sum},
                              #{name => view_b,
                                selector => #{instrument_name => a_counter},
                                aggregation_module => otel_aggregation_sum}
                              #{name => view_c,
                                selector => #{instrument_name => a_counter}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),

    Config;
init_per_testcase(multiple_readers, Config) ->
    application:load(opentelemetry_experimental),
    ok = application:set_env(opentelemetry_experimental, readers,
                             [#{module => otel_metric_reader,
                                config => #{exporter => {otel_metric_exporter_pid, self()},
                                            default_temporality_mapping => default_temporality_mapping()}},
                              #{module => otel_metric_reader,
                                config => #{exporter => {otel_metric_exporter_pid, self()},
                                            default_temporality_mapping => default_temporality_mapping(),
                                            default_aggregation_mapping =>
                                                #{?KIND_COUNTER => otel_aggregation_drop}}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),

    Config;
init_per_testcase(delta_counter, Config) ->
    application:load(opentelemetry_experimental),

    %% delta is the default for a counter with sum aggregation
    %% so no need to set any temporality mapping in the reader
    ok = application:set_env(opentelemetry_experimental, readers, [#{module => otel_metric_reader,
                                                                     config => #{exporter => {otel_metric_exporter_pid, self()},
                                                                                 default_temporality_mapping => default_temporality_mapping()}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),

    Config;
init_per_testcase(cumulative_counter, Config) ->
    CumulativeCounterTemporality = maps:put(?KIND_COUNTER, ?TEMPORALITY_CUMULATIVE, default_temporality_mapping()),
    application:load(opentelemetry_experimental),
    ok = application:set_env(opentelemetry_experimental, readers, [#{module => otel_metric_reader,
                                                                     config => #{exporter => {otel_metric_exporter_pid, self()},
                                                                                 default_temporality_mapping =>
                                                                                     CumulativeCounterTemporality}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),

    Config;
init_per_testcase(delta_explicit_histograms, Config) ->
    DeltaHistogramTemporality = maps:put(?KIND_HISTOGRAM, ?TEMPORALITY_DELTA, default_temporality_mapping()),
    application:load(opentelemetry_experimental),
    ok = application:set_env(opentelemetry_experimental, readers, [#{module => otel_metric_reader,
                                                                     config => #{exporter => {otel_metric_exporter_pid, self()},
                                                                                 default_temporality_mapping =>
                                                                                     DeltaHistogramTemporality}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),

    Config;
init_per_testcase(delta_observable_counter, Config) ->
    DeltaObservableCounterTemporality = maps:put(?KIND_OBSERVABLE_COUNTER, ?TEMPORALITY_DELTA, default_temporality_mapping()),
    application:load(opentelemetry_experimental),
    ok = application:set_env(opentelemetry_experimental, readers, [#{module => otel_metric_reader,
                                                                     config => #{exporter => {otel_metric_exporter_pid, self()},
                                                                                 default_temporality_mapping =>
                                                                                     DeltaObservableCounterTemporality}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),

    Config;
init_per_testcase(_, Config) ->
    application:load(opentelemetry_experimental),
    ok = application:set_env(opentelemetry_experimental, readers, [#{module => otel_metric_reader,
                                                                     config => #{exporter => {otel_metric_exporter_pid, self()},
                                                                                 default_temporality_mapping => default_temporality_mapping()}}]),

    {ok, _} = application:ensure_all_started(opentelemetry_experimental),


    Config.

end_per_testcase(_, _Config) ->
    ok = application:stop(opentelemetry_experimental),
    application:unload(opentelemetry_experimental),
    ok.

default_resource(_Config) ->
    Resource = otel_meter_provider:resource(),

    ?assertMatch(#{'process.executable.name' := <<"erl">>},
                 otel_attributes:map(otel_resource:attributes(Resource))),

    ok.

default_temporality_mapping() ->
    #{
        ?KIND_COUNTER => ?TEMPORALITY_DELTA,
        ?KIND_OBSERVABLE_COUNTER => ?TEMPORALITY_CUMULATIVE,
        ?KIND_UPDOWN_COUNTER => ?TEMPORALITY_DELTA,
        ?KIND_OBSERVABLE_UPDOWNCOUNTER => ?TEMPORALITY_CUMULATIVE,
        ?KIND_HISTOGRAM => ?TEMPORALITY_DELTA,
        ?KIND_OBSERVABLE_GAUGE => ?TEMPORALITY_CUMULATIVE
    }.

using_macros(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = m_counter,
    CounterDesc = <<"macro made counter description">>,
    CounterUnit = kb,

    Counter = ?create_counter(CounterName, #{description => CounterDesc,
                                             unit => CounterUnit}),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, ?lookup_instrument(CounterName)),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assertEqual(ok, otel_counter:add(Counter, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, ?counter_add(CounterName, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(m_counter, <<"macro made counter description">>, kb,
                      [{12, #{<<"c">> => <<"b">>}}]),

    ok.

float_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = f_counter,
    CounterDesc = <<"macro made counter description">>,
    CounterUnit = kb,

    Counter = ?create_counter(CounterName, #{description => CounterDesc,
                                             unit => CounterUnit}),

    ?assertEqual(ok, otel_counter:add(Counter, 10.3, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, ?counter_add(CounterName, 5.5, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, ?counter_add(CounterName, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(f_counter, <<"macro made counter description">>, kb,
                      [{20.8, #{<<"c">> => <<"b">>}}]),

    ok.

float_updown_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = f_counter,
    CounterDesc = <<"macro made updown counter description">>,
    CounterUnit = kb,

    Counter = ?create_updown_counter(CounterName, #{description => CounterDesc,
                                                    unit => CounterUnit}),

    ?assertEqual(ok, otel_updown_counter:add(Counter, 10.5, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, ?updown_counter_add(CounterName, -5.5, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, ?updown_counter_add(CounterName, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(f_counter, <<"macro made updown counter description">>, kb,
                      [{10.0, #{<<"c">> => <<"b">>}}]),

    ok.

float_histogram(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = f_histogram,
    CounterDesc = <<"macro made histogram description">>,
    CounterUnit = kb,

    Counter = ?create_histogram(CounterName, #{description => CounterDesc,
                                               unit => CounterUnit}),

    ?assertEqual(ok, otel_histogram:record(Counter, 10.3, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_histogram:record(Counter, 10.3, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, ?histogram_record(CounterName, 5.5, #{<<"c">> => <<"b">>})),

    %% float type accepts integers
    ?assertEqual(ok, ?histogram_record(CounterName, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=f_histogram,
                              data=#histogram{datapoints=Datapoints}}} ->
            AttributeBuckets =
                [{Attributes, Buckets, Min, Max, Sum}
                 || #histogram_datapoint{bucket_counts=Buckets,
                                         attributes=Attributes,
                                         min=Min,
                                         max=Max,
                                         sum=Sum}  <- Datapoints],
            ?assertEqual([], [{#{<<"c">> => <<"b">>}, [0,1,1,2,0,0,0,0,0,0,0,0,0,0,0,0], 5, 10.3, 31.1}]
                         -- AttributeBuckets, AttributeBuckets)
    after
        5000 ->
            ct:fail(histogram_receive_timeout)
    end,


    ok.

default_view(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = z_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_meter:create_counter(Meter, CounterName,
                                        #{description => CounterDesc,
                                          unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assertEqual(ok, otel_counter:add(Counter, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(z_counter, <<"counter description">>, kb, [{11, #{<<"c">> => <<"b">>}}]),

    ok.

provider_test(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_meter:create_counter(Meter, CounterName,
                                        #{description => CounterDesc,
                                          unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assertEqual(ok, otel_counter:add(Counter, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),

    %% converts counter to a float value
    ?assertEqual(ok, otel_counter:add(Counter, 5.0, #{<<"c">> => <<"b">>})),

    %% ignored because only positive measurements are allowed for counters
    ?assertEqual(ok, otel_counter:add(Counter, -10, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{16.0, #{<<"c">> => <<"b">>}}]),
    ?assertSumReceive(view_c, <<"counter description">>, kb, [{16.0, #{<<"c">> => <<"b">>}}]),

    %% sum agg is default delta temporality so counter will reset
    ?assertEqual(ok, otel_counter:add(Counter, 7, #{<<"c">> => <<"b">>})),
    otel_meter_server:force_flush(),
    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{7, #{<<"c">> => <<"b">>}},
                                                                 {0, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>}}]),

    ok.

view_creation_test(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_counter:create(Meter, CounterName,
                                  #{description => CounterDesc,
                                    unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assert(otel_meter_server:add_view(view_a, #{instrument_name => a_counter}, #{aggregation_module => otel_aggregation_sum})),

    {ok, View} = otel_view:new(#{instrument_name => a_counter}, #{aggregation_module => otel_aggregation_sum}),
    %% view name becomes the instrument name
    ?assertEqual(a_counter, View#view.name),

    Matches = otel_view:match_instrument_to_views(Counter, [View]),
    ?assertMatch([_], Matches),

    {ok, ViewUnitMatch} = otel_view:new(#{instrument_name => CounterName, instrument_unit => CounterUnit}, #{aggregation_module => otel_aggregation_sum}),
    ?assertMatch([{#view{}, _}], otel_view:match_instrument_to_views(Counter, [ViewUnitMatch])),

    {ok, ViewUnitNotMatch} = otel_view:new(#{instrument_name => CounterName, instrument_unit => not_matching}, #{aggregation_module => otel_aggregation_sum}),
    ?assertMatch([{undefined, _}], otel_view:match_instrument_to_views(Counter, [ViewUnitNotMatch])),

    %% views require a unique name
    ?assert(otel_meter_server:add_view(view_b, #{instrument_name => a_counter}, #{aggregation_module => otel_aggregation_sum})),
    %% ?assertNot(otel_meter_server:add_view(view_b, #{instrument_name => a_counter}, #{aggregation_module => otel_aggregation_sum})),

    %% only one view that matches all instruments can be allowed
    ?assert(otel_meter_server:add_view(view_c, #{}, #{aggregation_module => otel_aggregation_sum})),
    %% ?assertNot(otel_meter_server:add_view(view_d, #{}, #{aggregation_module => otel_aggregation_sum})),

    ?assert(otel_meter_server:add_view(#{instrument_name => b_counter}, #{aggregation_module => otel_aggregation_sum})),
    ?assert(otel_meter_server:add_view(#{instrument_name => c_counter}, #{aggregation_module => otel_aggregation_sum})),

    ok.

wildcard_view(_Config) ->
    Meter = opentelemetry_experimental:get_meter(),

    ViewCriteria = #{instrument_name => '*'},
    ViewConfig = #{aggregation_module => otel_aggregation_drop},

    ?assert(otel_meter_server:add_view(ViewCriteria, ViewConfig)),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_counter:create(Meter, CounterName,
                                  #{description => CounterDesc,
                                    unit => CounterUnit}),

    ?assertEqual(ok, otel_counter:add(Counter, 1, #{})),

    otel_meter_server:force_flush(),

    ?assertNotReceive(CounterName, CounterDesc, CounterUnit),

    {ok, View} = otel_view:new(ViewCriteria, ViewConfig),
    ?assertMatch([{#view{}, _}], otel_view:match_instrument_to_views(Counter, [View])),

    %% not possible to create wildcard views with a name
    {error, named_wildcard_view} = otel_view:new(view_name, ViewCriteria, ViewConfig),
    
    ok.

counter_add(_Config) ->
    Meter = opentelemetry_experimental:get_meter(),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_counter:create(Meter, CounterName,
                                  #{description => CounterDesc,
                                    unit => CounterUnit}),

    ?assertMatch(ok, otel_counter:add(Counter, 3, #{})),
    ok.

multiple_readers(_Config) ->
    Meter = opentelemetry_experimental:get_meter(),

    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    CounterA = otel_meter:create_counter(Meter, a_counter,
                                         #{description => CounterDesc,
                                           unit => CounterUnit}),
    CounterB = otel_meter:create_counter(Meter, b_counter,
                                         #{description => CounterDesc,
                                           unit => CounterUnit}),

    otel_meter_server:add_view(#{instrument_name => a_counter}, #{aggregation_module => otel_aggregation_sum}),
    otel_meter_server:add_view(#{instrument_name => b_counter}, #{}),

    ?assertEqual(ok, otel_counter:add(CounterA, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(CounterA, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(CounterA, 4, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(CounterA, 5, #{<<"c">> => <<"b">>})),

    ?assertEqual(ok, otel_counter:add(CounterB, 2, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    %% 2nd reader has counter set to drop so only 1 of b_counter is expected bc it does
    %% not set an aggregation in the view definition
    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{11, #{<<"c">> => <<"b">>}}]),
    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{11, #{<<"c">> => <<"b">>}}]),
    ?assertSumReceive(b_counter, <<"counter description">>, kb, [{2, #{<<"c">> => <<"b">>}}]),
    ?assertNotReceive(b_counter, <<"counter description">>, kb),

    ok.

explicit_histograms(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    HistogramName = a_histogram,
    HistogramDesc = <<"histogram description">>,
    HistogramUnit = ms,

    Histogram = otel_meter:create_histogram(Meter, HistogramName,
                                            #{description => HistogramDesc,
                                              unit => HistogramUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = HistogramName,
                             description = HistogramDesc,
                             kind = histogram,
                             unit = HistogramUnit}, Histogram),

    otel_meter_server:add_view(#{instrument_name => a_histogram}, #{}),

    ?assertEqual(ok, otel_histogram:record(Histogram, 20, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 30, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 44, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 100, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 20000, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=a_histogram,
                              data=#histogram{datapoints=Datapoints}}} ->
            AttributeBuckets =
                lists:sort([{Attributes, Buckets, Min, Max, Sum} || #histogram_datapoint{bucket_counts=Buckets,
                                                                                         attributes=Attributes,
                                                                                         min=Min,
                                                                                         max=Max,
                                                                                         sum=Sum}  <- Datapoints]),
            ?assertEqual([], [{#{<<"c">> => <<"b">>}, [0,0,0,1,1,0,1,0,0,0,0,0,0,0,0,1], 20, 20000, 20164},
                              {#{<<"a">> => <<"b">>, <<"d">> => <<"e">>}, [0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0], 30, 30, 30}]
                         -- AttributeBuckets, AttributeBuckets)
    after
        5000 ->
            ct:fail(histogram_receive_timeout)
    end,

    ok.

delta_explicit_histograms(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    HistogramName = a_histogram,
    HistogramDesc = <<"histogram description">>,
    HistogramUnit = ms,

    Histogram = otel_meter:create_histogram(Meter, HistogramName,
                                            #{description => HistogramDesc,
                                              unit => HistogramUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = HistogramName,
                             description = HistogramDesc,
                             kind = histogram,
                             unit = HistogramUnit}, Histogram),

    otel_meter_server:add_view(#{instrument_name => a_histogram}, #{}),


    ?assertEqual(ok, otel_histogram:record(Histogram, 20, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 30, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 44, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 100, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=a_histogram,
                              data=#histogram{datapoints=Datapoints}}} ->
            AttributeBuckets =
                lists:sort([{Attributes, Buckets, Min, Max, Sum} || #histogram_datapoint{bucket_counts=Buckets,
                                                                                         attributes=Attributes,
                                                                                         min=Min,
                                                                                         max=Max,
                                                                                         sum=Sum}  <- Datapoints]),
            ?assertEqual([], [{#{<<"c">> => <<"b">>}, [0,0,0,1,1,0,1,0,0,0,0,0,0,0,0,0], 20, 100, 164},
                              {#{<<"a">> => <<"b">>, <<"d">> => <<"e">>}, [0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0], 30, 30, 30}]
                         -- AttributeBuckets, AttributeBuckets)
    after
        5000 ->
            ct:fail(histogram_receive_timeout)
    end,

    ?assertEqual(ok, otel_histogram:record(Histogram, 88, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=a_histogram,
                              data=#histogram{datapoints=Datapoints1}}} ->
            AttributeBuckets1 =
                [{Attributes, Buckets, Min, Max, Sum} || #histogram_datapoint{bucket_counts=Buckets,
                                                                              attributes=Attributes,
                                                                              min=Min,
                                                                              max=Max,
                                                                              sum=Sum}  <- Datapoints1],
            ?assertEqual([], [{#{<<"c">> => <<"b">>}, [0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0], 88, 88, 88},
                              {#{<<"a">> => <<"b">>,<<"d">> => <<"e">>},
                               [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
                               infinity,-9.223372036854776e18,0}
                             ]
                         -- AttributeBuckets1, AttributeBuckets1)
    after
        5000 ->
            ct:fail(histogram_receive_timeout)
    end,

    ok.

delta_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_counter:create(Meter, CounterName,
                                  #{description => CounterDesc,
                                    unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    otel_meter_server:add_view(#{instrument_name => a_counter}, #{}),

    ?assertEqual(ok, otel_counter:add(Counter, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{6, #{<<"c">> => <<"b">>}}]),

    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),

    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 8, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{13, #{<<"c">> => <<"b">>}}]),

    ok.

cumulative_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_counter:create(Meter, CounterName,
                                  #{description => CounterDesc,
                                    unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    otel_meter_server:add_view(#{instrument_name => a_counter},
                               #{aggregation_module => otel_aggregation_sum}),

    ?assertEqual(ok, otel_counter:add(Counter, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{6, #{<<"c">> => <<"b">>}}]),

    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),

    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 7, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{18, #{<<"c">> => <<"b">>}}]),

    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 2, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(a_counter, <<"counter description">>, kb, [{23, #{<<"c">> => <<"b">>}}]),

    ok.

kill_reader(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = z_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_meter:create_counter(Meter, CounterName,
                                        #{description => CounterDesc,
                                          unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(z_counter, <<"counter description">>, kb, [{3, #{<<"c">> => <<"b">>}}]),

    %% counter is delta, so is reset to 0. take a measurement here before
    %% killer the reader to test that it isn't lost when the reader restarts
    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),

    [{_, ProviderSupPid, _, _}] = supervisor:which_children(otel_meter_provider_sup),
    {_, ReaderSup, _, _} = lists:keyfind(otel_metric_reader_sup, 1, supervisor:which_children(ProviderSupPid)),

    [ReaderPid] = [Pid || {_, Pid, _, _} <- supervisor:which_children(ReaderSup)],
    erlang:exit(ReaderPid, kill),

    %% loop until a new reader has started
    ?UNTIL([Pid || {_, Pid, _, _} <- supervisor:which_children(ReaderSup),
                   Pid =/= ReaderPid] =/= []),

    %% This will create an ignored duplicate Counter since the Instruments table
    %% is owned by the `otel_metrics_server' process
    Counter = otel_meter:create_counter(Meter, CounterName,
                                        #{description => CounterDesc,
                                          unit => CounterUnit}),

    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    %% 13 because we don't lose previous metrics for a reader after it crashes
    ?assertSumReceive(z_counter, <<"counter description">>, kb, [{13, #{<<"c">> => <<"b">>}}]),

    ok.

kill_server(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    ACounterName = a_counter,
    CounterName = z_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    ACounter = otel_meter:create_counter(Meter, ACounterName,
                                         #{description => CounterDesc,
                                           unit => CounterUnit}),
    Counter = otel_meter:create_counter(Meter, CounterName,
                                        #{description => CounterDesc,
                                          unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assertEqual(ok, otel_counter:add(ACounter, 2, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 3, #{<<"a">> => <<"b">>, <<"d">> => <<"e">>})),

    CurrentPid = erlang:whereis(?GLOBAL_METER_PROVIDER_REG_NAME),
    erlang:exit(erlang:whereis(?GLOBAL_METER_PROVIDER_REG_NAME), kill),

    %% wait until process has died and born again
    ?UNTIL(erlang:whereis(?GLOBAL_METER_PROVIDER_REG_NAME) =/= CurrentPid),
    ?UNTIL(erlang:whereis(?GLOBAL_METER_PROVIDER_REG_NAME) =/= undefined),

    %% TODO: Agh! need to supervise ETS tables so readers can crash and not then
    %% lose all existing Instrument/View matches
    ACounter = otel_meter:create_counter(Meter, ACounterName,
                                         #{description => CounterDesc,
                                           unit => CounterUnit}),
    Counter = otel_meter:create_counter(Meter, CounterName,
                                        #{description => CounterDesc,
                                          unit => CounterUnit}),

    ?assertEqual(ok, otel_counter:add(Counter, 4, #{<<"c">> => <<"b">>})),
    ?assertEqual(ok, otel_counter:add(Counter, 5, #{<<"c">> => <<"b">>})),

    otel_meter_server:force_flush(),

    %% at this time a crashed meter server will mean losing the recorded metrics up to that point
    ?assertSumReceive(a_counter, <<"counter description">>, kb, []),
    ?assertSumReceive(z_counter, <<"counter description">>, kb, [{9, #{<<"c">> => <<"b">>}}]),

    ok.

observable_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_counter,
    CounterDesc = <<"observable counter description">>,
    CounterUnit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName},
                                       #{aggregation_module => otel_aggregation_sum})),

    Counter = otel_meter:create_observable_counter(Meter, CounterName,
                                                   fun(_Args) ->
                                                           MeasurementAttributes1 = #{<<"a">> => <<"b">>},
                                                           MeasurementAttributes2 = #{<<"c">> => <<"d">>},
                                                           [{4, MeasurementAttributes1},
                                                            {5, MeasurementAttributes2}]
                                                   end,
                                                   [],
                                                   #{description => CounterDesc,
                                                     unit => CounterUnit}),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = observable_counter,
                             unit = CounterUnit,
                             callback=_}, Counter),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, <<"observable counter description">>, kb, [{4, #{<<"a">> => <<"b">>}},
                                                                              {5, #{<<"c">> => <<"d">>}}]),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, <<"observable counter description">>, kb, [{4, #{<<"a">> => <<"b">>}},
                                                                              {5, #{<<"c">> => <<"d">>}}]),

    ok.

observable_updown_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_updown_counter,
    CounterDesc = <<"observable updown counter description">>,
    CounterUnit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName}, #{aggregation_module => otel_aggregation_sum})),

    Counter = otel_meter:create_observable_updowncounter(Meter, CounterName,
                                                         fun(_) ->
                                                                 MeasurementAttributes = #{<<"a">> => <<"b">>},
                                                                 [{5, MeasurementAttributes}]
                                                         end,
                                                         [],
                                                         #{description => CounterDesc,
                                                           unit => CounterUnit}),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = observable_updowncounter,
                             unit = CounterUnit,
                             callback=_}, Counter),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, <<"observable updown counter description">>, kb, [{5, #{<<"a">> => <<"b">>}}]),

    ok.

observable_gauge(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_gauge,
    CounterDesc = <<"observable gauge description">>,
    CounterUnit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName}, #{aggregation_module => otel_aggregation_last_value})),

    Counter = otel_meter:create_observable_gauge(Meter, CounterName,
                                                 fun(_) ->
                                                         [{5, #{<<"a">> => <<"b">>}}]
                                                 end,
                                                 [],
                                                 #{description => CounterDesc,
                                                   unit => CounterUnit}),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = observable_gauge,
                             unit = CounterUnit,
                             callback=_}, Counter),

    otel_meter_server:force_flush(),

    ?assertLastValueReceive(CounterName, CounterDesc, CounterUnit, [{5, #{<<"a">> => <<"b">>}}]),

    ok.

multi_instrument_callback(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_counter,
    CounterDesc = <<"observable counter description">>,

    GaugeName = a_observable_gauge,
    GaugeDesc = <<"observable gauge description">>,

    Unit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName}, #{aggregation_module => otel_aggregation_sum})),

    Counter = otel_observable_counter:create(Meter, CounterName, #{description => CounterDesc, unit => Unit}),
    Gauge = otel_observable_gauge:create(Meter, GaugeName, #{description => GaugeDesc, unit => Unit}),

    otel_meter:register_callback(Meter, [Counter, Gauge],
                                 fun(_) ->
                                         [{CounterName, [{4, #{<<"a">> => <<"b">>}}]},
                                          {GaugeName, [{5, #{<<"a">> => <<"b">>}}]}]
                                 end, []),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, CounterDesc, Unit, [{4, #{<<"a">> => <<"b">>}}]),
    ?assertLastValueReceive(GaugeName, GaugeDesc, Unit, [{5, #{<<"a">> => <<"b">>}}]),

    ok.

sync_filtered_attributes(_Config) ->
    Meter = opentelemetry_experimental:get_meter(
              opentelemetry:get_application_scope(?MODULE)),

    CounterName = a_counter,
    CounterDesc = <<"counter description">>,
    CounterUnit = kb,

    Counter = otel_counter:create(Meter, CounterName,
                                  #{description => CounterDesc,
                                    unit => CounterUnit}),
    ?assertMatch(#instrument{meter = {otel_meter_default, _},
                             module = otel_meter_default,
                             name = CounterName,
                             description = CounterDesc,
                             kind = counter,
                             unit = CounterUnit}, Counter),

    ?assert(otel_meter_server:add_view(view_a, #{instrument_name => CounterName},
                                       #{aggregation_module => otel_aggregation_sum,
                                         attribute_keys => [a, b]})),

    ?assertEqual(ok, otel_counter:add(Counter, 2, #{a => 1, b => 2, c => 3})),
    ?assertEqual(ok, otel_counter:add(Counter, 5, #{a => 1, b => 2})),
    ?assertEqual(ok, ?counter_add(CounterName, 5, #{a => 1, b => 2, c => 3})),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, CounterDesc, kb,
                      [{7, #{a => 1, b => 2, c => 3}}, {5, #{a => 1, b => 2}}]),
    ?assertSumReceive(view_a, CounterDesc, kb,
                      [{12, #{a => 1, b => 2}}]),


    ok.

async_filtered_attributes(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_counter,
    CounterDesc = <<"observable counter description">>,
    CounterUnit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName},
                                       #{aggregation_module => otel_aggregation_sum,
                                         attribute_keys => [a]})),

    Counter = otel_meter:create_observable_counter(Meter, CounterName,
                                                   fun(_Args) ->
                                                           MeasurementAttributes = #{a => b,
                                                                                     c => d},
                                                           [{4, MeasurementAttributes}]
                                                   end,
                                                   [],
                                                   #{description => CounterDesc,
                                                     unit => CounterUnit}),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = observable_counter,
                             unit = CounterUnit,
                             callback=_}, Counter),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, <<"observable counter description">>, kb, [{4, #{a => b}}]),

    ok.

delta_observable_counter(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_counter,
    CounterDesc = <<"observable counter description">>,
    CounterUnit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName}, #{aggregation_module => otel_aggregation_sum})),

    Counter = otel_meter:create_observable_counter(Meter, CounterName,
                                                   fun(_Args) ->
                                                           MeasurementAttributes = #{<<"a">> => <<"b">>},
                                                           [{4, MeasurementAttributes}]
                                                   end,
                                                   [],
                                                   #{description => CounterDesc,
                                                     unit => CounterUnit}),

    ?assertMatch(#instrument{meter = {DefaultMeter,_},
                             module = DefaultMeter,
                             name = CounterName,
                             description = CounterDesc,
                             kind = observable_counter,
                             unit = CounterUnit,
                             callback=_}, Counter),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, <<"observable counter description">>, kb, [{4, #{<<"a">> => <<"b">>}}]),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName, <<"observable counter description">>, kb, [{0, #{<<"a">> => <<"b">>}}]),

    ok.

bad_observable_return(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    CounterName = a_observable_counter,
    CounterName2 = b_observable_counter,
    CounterDesc = <<"observable counter description">>,
    CounterDesc2 = <<"observable counter 2 description">>,
    CounterUnit = kb,

    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName}, #{})),
    ?assert(otel_meter_server:add_view(#{instrument_name => CounterName2}, #{})),

    _Counter = otel_meter:create_observable_counter(Meter, CounterName,
                                                    fun(_Args) ->
                                                            not_a_list
                                                    end,
                                                    [],
                                                    #{description => CounterDesc,
                                                      unit => CounterUnit}),

    _Counter2 = otel_meter:create_observable_counter(Meter, CounterName2,
                                                     fun(_Args) ->
                                                             [{not_a_number, #{}},
                                                              {7, not_a_map},
                                                              {8, #{}}]
                                                     end,
                                                     [],
                                                     #{description => CounterDesc2,
                                                       unit => CounterUnit}),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName2, <<"observable counter 2 description">>, kb, [{8, #{}}]),

    otel_meter_server:force_flush(),

    ?assertSumReceive(CounterName2, <<"observable counter 2 description">>, kb, [{8, #{}}]),

    ok.

advisory_params(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    % explicit_bucket_boundaries allowed only for histograms
    Counter = otel_counter:create(Meter, invalid_1,
                                  #{advisory_params => #{explicit_bucket_boundaries => [1, 2, 3]}}),
    ?assertEqual(Counter#instrument.advisory_params, #{}),
    
    % advisory parameters different from explicit_bucket_boundaries are not allowed
    Counter1 = otel_counter:create(Meter, invalid_2, #{advisory_params => #{invalid => invalid}}),
    ?assertEqual(Counter1#instrument.advisory_params, #{}),
    
    % explicit_bucket_boundaries should be an ordered list of numbers
    Histo1 = otel_histogram:create(Meter, invalid_3,
                                  #{advisory_params => #{explicit_bucket_boundaries => invalid}}),
    ?assertEqual(Histo1#instrument.advisory_params, #{}),
    
    Histo2 = otel_histogram:create(Meter, invalid_4,
                                  #{advisory_params => #{explicit_bucket_boundaries => [2,1,4]}}),
    ?assertEqual(Histo2#instrument.advisory_params, #{}),

    % when valid use the explicit_bucket_boundaries from advisory_params if not set in a view
    Histogram = otel_histogram:create(Meter, a_histogram,
                                  #{advisory_params => #{explicit_bucket_boundaries => [10, 20, 30]}}),
    ?assertEqual(Histogram#instrument.advisory_params, #{explicit_bucket_boundaries => [10, 20, 30]}),

    ?assertEqual(ok, otel_histogram:record(Histogram, 15, #{<<"a">> => <<"1">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 50, #{<<"a">> => <<"1">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 26, #{<<"a">> => <<"2">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=a_histogram,
                              data=#histogram{datapoints=Datapoints}}} ->
            AttributeBuckets =
                lists:sort([{Attributes, Buckets, Min, Max, Sum} || #histogram_datapoint{bucket_counts=Buckets,
                                                                                         attributes=Attributes,
                                                                                         min=Min,
                                                                                         max=Max,
                                                                                         sum=Sum} <- Datapoints]),
            ?assertEqual([], [{#{<<"a">> => <<"1">>}, [0,1,0,1], 15, 50, 65},
                              {#{<<"a">> => <<"2">>}, [0,0,1,0], 26, 26, 26}]
                         -- AttributeBuckets, AttributeBuckets)
    after
        5000 ->
            ct:fail(histogram_receive_timeout)
    end,

    % explicit_bucket_boundaries from view have precedence
    ?assert(otel_meter_server:add_view(view, #{instrument_name => b_histogram}, #{
        aggregation_module => otel_aggregation_histogram_explicit,
        aggregation_options => #{explicit_bucket_boundaries => [10, 100]}})),

    HistogramB = otel_histogram:create(Meter, b_histogram,
                                  #{advisory_params => #{explicit_bucket_boundaries => [10, 20, 30]}}),
    ?assertEqual(HistogramB#instrument.advisory_params, #{explicit_bucket_boundaries => [10, 20, 30]}),

    ?assertEqual(ok, otel_histogram:record(HistogramB, 15, #{<<"a">> => <<"1">>})),
    ?assertEqual(ok, otel_histogram:record(HistogramB, 50, #{<<"a">> => <<"1">>})),
    ?assertEqual(ok, otel_histogram:record(HistogramB, 26, #{<<"a">> => <<"2">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=view,
                              data=#histogram{datapoints=DatapointsB}}} ->
            AttributeBucketsB =
                lists:sort([{Attributes, Buckets, Min, Max, Sum} || #histogram_datapoint{bucket_counts=Buckets,
                                                                                         attributes=Attributes,
                                                                                         min=Min,
                                                                                         max=Max,
                                                                                         sum=Sum} <- DatapointsB]),
            ?assertEqual([], [{#{<<"a">> => <<"1">>}, [0,2,0], 15, 50, 65},
                              {#{<<"a">> => <<"2">>}, [0,1,0], 26, 26, 26}]
                         -- AttributeBucketsB, AttributeBucketsB)
    after
        1000 ->
            ct:fail(histogram_receive_timeout)
    end.

histogram_aggregation_options(_Config) ->
    DefaultMeter = otel_meter_default,

    Meter = opentelemetry_experimental:get_meter(),
    ?assertMatch({DefaultMeter, _}, Meter),

    ?assert(otel_meter_server:add_view(view, #{instrument_name => histogram}, #{
        aggregation_module => otel_aggregation_histogram_explicit,
        aggregation_options => #{explicit_bucket_boundaries => [10, 100]}})),

    Histogram = otel_histogram:create(Meter, histogram, #{}),

    ?assertEqual(ok, otel_histogram:record(Histogram, 15, #{<<"a">> => <<"1">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 50, #{<<"a">> => <<"1">>})),
    ?assertEqual(ok, otel_histogram:record(Histogram, 26, #{<<"a">> => <<"2">>})),

    otel_meter_server:force_flush(),

    receive
        {otel_metric, #metric{name=view,
                              data=#histogram{datapoints=DatapointsB}}} ->
            AttributeBucketsB =
                lists:sort([{Attributes, Buckets, Min, Max, Sum} || #histogram_datapoint{bucket_counts=Buckets,
                                                                                         attributes=Attributes,
                                                                                         min=Min,
                                                                                         max=Max,
                                                                                         sum=Sum} <- DatapointsB]),
            ?assertEqual([], [{#{<<"a">> => <<"1">>}, [0,2,0], 15, 50, 65},
                              {#{<<"a">> => <<"2">>}, [0,1,0], 26, 26, 26}]
                         -- AttributeBucketsB, AttributeBucketsB)
    after
        1000 ->
            ct:fail(histogram_receive_timeout)
    end.