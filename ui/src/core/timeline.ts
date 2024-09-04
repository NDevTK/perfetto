// Copyright (C) 2018 The Android Open Source Project
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import {assertTrue} from '../base/logging';
import {time, TimeSpan} from '../base/time';
import {HighPrecisionTimeSpan} from '../base/high_precision_time_span';
import {Area} from './selection_manager';
import {raf} from './raf_scheduler';
import {HighPrecisionTime} from '../base/high_precision_time';

interface Range {
  start?: number;
  end?: number;
}

const MIN_DURATION = 10;

/**
 * State that is shared between several frontend components, but not the
 * controller. This state is updated at 60fps.
 */
export class TimelineImpl {
  private _visibleWindow: HighPrecisionTimeSpan;
  private readonly traceSpan: TimeSpan;

  // This is a giant hack. Basically, removing visible window from the state
  // means that we no longer update the state periodically while navigating
  // the timeline, which means that controllers are not running. This keeps
  // making null edits to the store which triggers the controller to run.
  // This function is injected from Globals.initialize() to avoid a dependency
  // on the State.
  // TODO(stevegolton): When we remove controllers, we can remove this!
  retriggerControllersOnChange: () => void = () => {};

  // This is used to calculate the tracks within a Y range for area selection.
  areaY: Range = {};
  private _selectedArea?: Area;

  constructor(traceSpan: TimeSpan) {
    this.traceSpan = traceSpan;
    this._visibleWindow = HighPrecisionTimeSpan.fromTime(
      traceSpan.start,
      traceSpan.end,
    );
  }

  // TODO: there is some redundancy in the fact that both |visibleWindowTime|
  // and a |timeScale| have a notion of time range. That should live in one
  // place only.

  zoomVisibleWindow(ratio: number, centerPoint: number) {
    this._visibleWindow = this._visibleWindow
      .scale(ratio, centerPoint, MIN_DURATION)
      .fitWithin(this.traceSpan.start, this.traceSpan.end);

    raf.scheduleRedraw();
    this.retriggerControllersOnChange();
  }

  panVisibleWindow(delta: number) {
    this._visibleWindow = this._visibleWindow
      .translate(delta)
      .fitWithin(this.traceSpan.start, this.traceSpan.end);

    raf.scheduleRedraw();
    this.retriggerControllersOnChange();
  }

  // Given a timestamp, if |ts| is not currently in view move the view to
  // center |ts|, keeping the same zoom level.
  panToTimestamp(ts: time) {
    if (this._visibleWindow.contains(ts)) return;
    // TODO(hjd): This is an ugly jump, we should do a smooth pan instead.
    const halfDuration = this.visibleWindow.duration / 2;
    const newStart = new HighPrecisionTime(ts).subNumber(halfDuration);
    const newWindow = new HighPrecisionTimeSpan(
      newStart,
      this._visibleWindow.duration,
    );
    this.updateVisibleTimeHP(newWindow);
  }

  // Set the highlight box to draw
  selectArea(
    start: time,
    end: time,
    tracks = this._selectedArea ? this._selectedArea.trackUris : [],
  ) {
    assertTrue(
      end >= start,
      `Impossible select area: start [${start}] >= end [${end}]`,
    );
    this._selectedArea = {start, end, trackUris: tracks};
    raf.scheduleFullRedraw();
  }

  deselectArea() {
    this._selectedArea = undefined;
    raf.scheduleRedraw();
  }

  get selectedArea(): Area | undefined {
    return this._selectedArea;
  }

  // Set visible window using an integer time span
  updateVisibleTime(ts: TimeSpan) {
    this.updateVisibleTimeHP(HighPrecisionTimeSpan.fromTime(ts.start, ts.end));
  }

  // Set visible window using a high precision time span
  updateVisibleTimeHP(ts: HighPrecisionTimeSpan) {
    this._visibleWindow = ts
      .clampDuration(MIN_DURATION)
      .fitWithin(this.traceSpan.start, this.traceSpan.end);

    raf.scheduleRedraw();
    this.retriggerControllersOnChange();
  }

  // Get the bounds of the visible window as a high-precision time span
  get visibleWindow(): HighPrecisionTimeSpan {
    return this._visibleWindow;
  }
}