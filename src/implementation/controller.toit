// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services

import ..artemis as artemis
import ..api as api

class Controller extends services.ServiceResourceProxy:
  constructor client/api.ArtemisClient? --mode/int:
    if not client: throw "Artemis unavailable"
    handle := client.controller-open --mode=mode
    super client handle

  static run client/api.ArtemisClient? --mode/int [block] -> none:
    controller := Controller client --mode=mode
    try:
      block.call
    finally:
      // It is important that we give Artemis a chance to react to
      // the close event, even if we're out of time.
      critical-do --no-respect-deadline: controller.close
