// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import .api.artemis

service_/ArtemisService? ::= (ArtemisClient).open --if_absent=: null

version -> string:
  service := service_
  if not service: throw "Not running on Artemis"
  return service.version
