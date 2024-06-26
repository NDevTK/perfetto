--
-- Copyright 2024 The Android Open Source Project
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     https://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.


-- Returns an instance of `RawMarkerTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO FUNCTION _export_firefox_thread_markers()
RETURNS STRING
AS
SELECT json_object(
      'data', json_array(),
      'name', json_array(),
      'startTime', json_array(),
      'endTime', json_array(),
      'phase', json_array(),
      'category', json_array(),
      -- threadId?: Tid[]
      'length', 0);

-- Returns an instance of `SamplesTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO MACRO _export_firefox_samples_table(samples_table TableOrSubquery)
RETURNS Expr
AS (
  SELECT
    json_object(
      -- responsiveness?: Array<?Milliseconds>
      -- eventDelay?: Array<?Milliseconds>
      'stack', json_group_array(stack ORDER BY idx),
      'time',  json_group_array(time ORDER BY idx),
      'weight', NULL,
      'weightType', 'samples',
      -- threadCPUDelta?: Array<number | null>
      -- threadId?: Tid[]
      'length', COUNT(*))
  FROM samples_table
);

-- Returns an instance of `StackTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO MACRO _export_firefox_stack_table(stack_table TableOrSubquery)
RETURNS Expr
AS (
  SELECT
    json_object(
      'frame', json_group_array(frame ORDER BY idx),
      'category', json_group_array(category ORDER BY idx),
      'subcategory', json_group_array(subcategory ORDER BY idx),
      'prefix', json_group_array(prefix ORDER BY idx),
      'length', COUNT(*))
  FROM stack_table
);

-- Returns an instance of `FrameTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO MACRO _export_firefox_frame_table(frame_table TableOrSubquery)
RETURNS Expr
AS (
  SELECT
    json_object(
      'address', json_group_array(address ORDER BY idx),
      'inlineDepth', json_group_array(inline_depth ORDER BY idx),
      'category', json_group_array(category ORDER BY idx),
      'subcategory', json_group_array(subcategory ORDER BY idx),
      'func', json_group_array(func ORDER BY idx),
      'nativeSymbol', json_group_array(native_symbol ORDER BY idx),
      'innerWindowID', json_group_array(inner_window_id ORDER BY idx),
      'implementation', json_group_array(implementation ORDER BY idx),
      'line', json_group_array(line ORDER BY idx),
      'column', json_group_array(column ORDER BY idx),
      'length', COUNT(*))
  FROM frame_table
);

-- Returns an array of strings.
CREATE PERFETTO MACRO _export_firefox_string_array(string_table TableOrSubquery)
RETURNS Expr
AS (
  SELECT json_group_array(str ORDER BY idx)
  FROM string_table
);

-- Returns an instance of `FuncTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO MACRO _export_firefox_func_table(func_table TableOrSubquery)
RETURNS Expr
AS (
  SELECT
    json_object(
      'name', json_group_array(name ORDER BY idx),
      'isJS', json_group_array(is_js ORDER BY idx),
      'relevantForJS', json_group_array(relevant_for_js ORDER BY idx),
      'resource', json_group_array(resource ORDER BY idx),
      'fileName', json_group_array(file_name ORDER BY idx),
      'lineNumber', json_group_array(line_number ORDER BY idx),
      'columnNumber', json_group_array(column_number ORDER BY idx),
      'length', COUNT(*))
  FROM func_table
);

-- Returns an empty instance of `NativeSymbolTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO FUNCTION _export_firefox_native_symbol_table()
RETURNS STRING
AS
SELECT
  json_object(
    'libIndex', json_array(),
    'address', json_array(),
    'name', json_array(),
    'functionSize', json_array(),
    'length', 0);


-- Returns an empty instance of `ResourceTable` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE PERFETTO FUNCTION _export_firefox_resource_table()
RETURNS STRING
AS
SELECT
  json_object(
    'length', 0,
    'lib', json_array(),
    'name', json_array(),
    'host', json_array(),
    'type', json_array());

-- Returns an instance of `Thread` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
-- for the given `utid`.
CREATE PERFETTO FUNCTION _export_firefox_thread(utid INT)
RETURNS STRING
AS
WITH
  symbol AS (
    SELECT
      symbol_set_id,
      RANK()
        OVER (
          PARTITION BY symbol_set_id
          ORDER BY id DESC
          RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        )
        - 1 AS inline_depth,
      COUNT() OVER (PARTITION BY symbol_set_id) - 1 AS max_inline_depth,
      name
    FROM stack_profile_symbol
  ),
  callsite_base AS (
    SELECT
      id,
      parent_id,
      name,
      symbol_set_id,
      IIF(inline_count = 0, 0, inline_count - 1) AS max_inline_depth
    FROM
      (
        SELECT
          spc.id,
          spc.parent_id,
          COALESCE(s.name, spf.name, '') AS name,
          sfp.symbol_set_id,
          (
            SELECT COUNT(*)
            FROM stack_profile_symbol s
            WHERE s.symbol_set_id = sfp.symbol_set_id
          ) AS inline_count
        FROM stack_profile_callsite sfc, stack_profile_frame AS spf
        ON (c.frame_id = spf.id)
      )
  ),
  callsite_recursive AS (
    SELECT
      spc.id,
      spc.parent_id,
      spc.frame_id,
      TRUE AS is_leaf
    FROM
      (SELECT DISTINCT callsite_id FROM perf_sample WHERE utid = $utid) s,
      stack_profile_callsite spc
    ON (spc.id = s.callsite_id)
    UNION ALL
    SELECT
      parent.id,
      parent.parent_id,
      parent.frame_id,
      FALSE AS is_leaf
    FROM callsite_recursive AS child, stack_profile_callsite AS parent
    ON (child.parent_id = parent.id)
  ),
  unique_callsite AS (
    SELECT DISTINCT * FROM callsite_recursive
  ),
  expanded_callsite_base AS (
    SELECT
      c.id,
      c.parent_id,
      c.is_leaf,
      c.frame_id,
      COALESCE(s.name, spf.name, '') AS name,
      COALESCE(s.inline_depth, 0) AS inline_depth,
      COALESCE(s.max_inline_depth, 0) AS max_inline_depth
    FROM unique_callsite c, stack_profile_frame AS spf
    ON (c.frame_id = spf.id)
    LEFT JOIN symbol s
      USING (symbol_set_id)
  ),
  expanded_callsite AS (
    SELECT
      *,
      DENSE_RANK() OVER (ORDER BY id, inline_depth) - 1 AS stack_table_index,
      DENSE_RANK()
        OVER (ORDER BY frame_id, inline_depth) - 1 AS frame_table_index,
      DENSE_RANK() OVER (ORDER BY name) - 1 AS func_table_index,
      DENSE_RANK() OVER (ORDER BY name) - 1 AS string_table_index
    FROM expanded_callsite_base
  ),
  string_table AS (
    SELECT DISTINCT
      string_table_index AS idx,
      name AS str
    FROM
      expanded_callsite
  ),
  func_table AS (
    SELECT DISTINCT
      func_table_index AS idx,
      string_table_index AS name,
      FALSE AS is_js,
      FALSE AS relevant_for_js,
      - 1 AS resource,
      NULL AS file_name,
      NULL AS line_number,
      NULL AS column_number
    FROM expanded_callsite
  ),
  frame_table AS (
    SELECT DISTINCT
      frame_table_index AS idx,
      -1 AS address,
      inline_depth,
      0 AS category,
      0 AS subcategory,
      func_table_index AS func,
      NULL AS native_symbol,
      NULL AS inner_window_id,
      NULL AS implementation,
      NULL AS line,
      NULL AS column
    FROM expanded_callsite
  ),
  stack_table AS (
    SELECT
      stack_table_index AS idx,
      frame_table_index AS frame,
      0 AS category,
      0 AS subcategory,
      (
        SELECT stack_table_index
        FROM expanded_callsite AS parent
        WHERE
          (
            child.inline_depth = 0
            AND child.parent_id = parent.id
            AND parent.inline_depth = parent.max_inline_depth)
          OR (
            child.inline_depth - 1 = parent.inline_depth
            AND child.id = parent.id)
      ) AS prefix
    FROM expanded_callsite AS child
  ),
  samples_table AS (
    SELECT
      ROW_NUMBER() OVER(ORDER BY s.id) - 1 AS idx,
      s.ts AS time,
      (
        SELECT stack_table_index
        FROM expanded_callsite c
        WHERE s.callsite_id = c.id AND c.inline_depth = c.max_inline_depth
      ) AS stack
    FROM perf_sample AS s
    WHERE utid = $utid
  )
SELECT
  json_object(
    'processType', 'default',
    -- processStartupTime: Milliseconds
    -- processShutdownTime: Milliseconds | null
    -- registerTime: Milliseconds
    -- unregisterTime: Milliseconds | null
    -- pausedRanges: PausedRange[]
    -- showMarkersInTimeline?: boolean
    'name', COALESCE(thread.name, ''),
    'isMainThread', FALSE,
    -- 'eTLD+1'?: string
    -- processName?: string
    -- isJsTracer?: boolean
    'pid', COALESCE(process.pid, 0),
    'tid', COALESCE(thread.tid, 0),
    'samples', _export_firefox_samples_table!(samples_table),
    -- jsAllocations?: JsAllocationsTable
    -- nativeAllocations?: NativeAllocationsTable
    'markers', json(_export_firefox_thread_markers()),
    'stackTable', _export_firefox_stack_table!(stack_table),
    'frameTable', _export_firefox_frame_table!(frame_table),
    'stringArray', _export_firefox_string_array!(string_table),
    'funcTable', _export_firefox_func_table!(func_table),
    'resourceTable', json(_export_firefox_resource_table()),
    'nativeSymbols', json(_export_firefox_native_symbol_table())
    -- jsTracer?: JsTracerTable
    -- isPrivateBrowsing?: boolean
    -- userContextId?: number
  )
FROM thread, process
USING (upid)
WHERE utid = $utid;

-- Returns an array of `Thread` instances as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
-- for each thread present in the trace.
CREATE PERFETTO FUNCTION _export_firefox_threads()
RETURNS STRING
AS
SELECT json_group_array(json(_export_firefox_thread(utid))) FROM thread;

-- Returns an instance of `ProfileMeta` as defined in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
CREATE
  PERFETTO FUNCTION _export_firefox_meta()
RETURNS STRING
AS
SELECT
  json_object(
    'interval', 1,
    'startTime', 0,
    -- startTime: Milliseconds
    -- endTime?: Milliseconds
    -- profilingStartTime?: Milliseconds
    -- profilingEndTime?: Milliseconds
    -- processType: number
    'processType',
    0,  -- default
    -- extensions?: ExtensionTable
    -- categories?: CategoryList
    'categories',
    json_array(
      json_object(
        'name',
        'Other',
        'color',
        'grey',
        'subcategories',
        json_array('Other'))),
    -- product: 'Firefox' | string
    'product',
    'Perfetto',
    -- stackwalk: 0 | 1
    'stackwalk',
    1,
    -- debug?: boolean
    -- version: number
    'version',
    29,  -- Taken from a generated profile
    -- preprocessedProfileVersion: number
    'preprocessedProfileVersion',
    48,  -- Taken from a generated profile
    -- abi?: string
    -- misc?: string
    -- oscpu?: string
    -- mainMemory?: Bytes
    -- platform?: 'Android' | 'Windows' | 'Macintosh' | 'X11' | string
    -- toolkit?: 'gtk' | 'gtk3' | 'windows' | 'cocoa' | 'android' | string
    -- appBuildID?: string
    -- arguments?: string
    -- sourceURL?: string
    -- physicalCPUs?: number
    -- logicalCPUs?: number
    -- CPUName?: string
    -- symbolicated?: boolean
    -- symbolicationNotSupported?: boolean
    -- updateChannel?: 'default' | 'nightly' | 'nightly-try' | 'aurora' | 'beta' | 'release' | 'esr' | string
    -- visualMetrics?: VisualMetrics
    -- configuration?: ProfilerConfiguration
    'markerSchema', json_array(),
    'sampleUnits', json_object('time', 'ms', 'eventDelay', 'ms', 'threadCPUDelta', 'µs')
    -- device?: string
    -- importedFrom?: string
    -- usesOnlyOneStackType?: boolean
    -- doesNotUseFrameImplementation?: boolean
    -- sourceCodeIsNotOnSearchfox?: boolean
    -- extra?: ExtraProfileInfoSection[]
    -- initialVisibleThreads?: ThreadIndex[]
    -- initialSelectedThreads?: ThreadIndex[]
    -- keepProfileThreadOrder?: boolean
    -- gramsOfCO2ePerKWh?: number
  );

-- Dumps all trace data as a Firefox profile json string
-- See `Profile` in
-- https://github.com/firefox-devtools/profiler/blob/main/src/types/profile.js
-- Also
-- https://firefox-source-docs.mozilla.org/tools/profiler/code-overview.html
--
-- You would probably want to download the generated json and then open at
-- https://https://profiler.firefox.com
-- You can easily do this from the UI via the following SQL
-- `SELECT CAST(export_to_firefox_profile() AS BLOB) AS profile;`
-- The result will have a link for you to download this json as a file.
CREATE PERFETTO FUNCTION export_to_firefox_profile()
-- Json profile
RETURNS STRING
AS
SELECT
  json_object(
    'meta', json(_export_firefox_meta()),
    'libs', json_array(),
    'pages', NULL,
    'counters', NULL,
    'profilerOverhead', NULL,
    'threads', json(_export_firefox_threads()),
    'profilingLog', NULL,
    'profileGatheringLog', NULL);
