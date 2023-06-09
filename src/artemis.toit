// Copyright (C) 2023 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import system.services show ServiceResourceProxy
import uuid

import .api as api
import .implementation.container as implementation
import .implementation.controller as implementation
import .implementation.device as implementation

DEFAULT_TIMEOUT_RUN_OFFLINE_ ::= Duration --m=5

artemis_client_/api.ArtemisClient? ::= (api.ArtemisClient).open
    --if_absent=: null

/**
Whether the Artemis service is available.
*/
available -> bool:
  return artemis_client_ != null

/**
Returns the version of the Artemis service.
*/
version -> string:
  client := artemis_client_
  if not client: throw "Artemis unavailable"
  return client.version

/**
Runs the $block while forcing Artemis to try go online
  even if it is not scheduled to do so yet.

The Artemis service will attempt to stay connected as
  long as the $block is still executing.
*/
run --online/bool [block] -> none:
  if not online: throw "Bad Argument"
  implementation.Controller.run artemis_client_ block
      --mode=api.ArtemisService.CONTROLLER_MODE_ONLINE

/**
Runs the $block while forcing Artemis to stay offline.

The Artemis service guarantees to stay disconnected as
  long as the $block is still executing.
*/
run --offline/bool [block] -> none
    --timeout/Duration?=DEFAULT_TIMEOUT_RUN_OFFLINE_:
  if not offline: throw "Bad Argument"
  with_timeout timeout:
    implementation.Controller.run artemis_client_ block
        --mode=api.ArtemisService.CONTROLLER_MODE_OFFLINE

/**
The $device is a local representation of the present physical
  or logical device running the Artemis service.
*/
device/Device ::= implementation.Device artemis_client_

/**
A physical or logical device running the Artemis service.
*/
interface Device:
  /**
  Returns the unique Artemis $id of the device.

  The $id is guaranteed to be unique among all devices that
    belong to a specific organization.
  */
  id -> uuid.Uuid

/**
A container is a schedulable unit of execution that runs
  in isolation from the system and the other containers
  on a device.

The containers on a device are managed by Artemis. They
  are installed and uninstalled when Artemis synchronizes
  with the cloud. After a container has been installed
  on a device, Artemis takes care of scheduling it based
  on its triggers and flags.

Use $Container.current to get access to the currently
  executing container.
*/
interface Container:
  /**
  Returns the currently executing container.
  */
  static current ::= implementation.ContainerCurrent artemis_client_

  /**
  Restarts this container.

  If a $delay is provided, Artemis will try to delay the
    restart for the specified amount of time. The container
    may restart early on exceptional occasions, such as a
    reboot after the loss of power.

  If no other jobs are keeping the device busy, delayed
    restarts allow Artemis to reduce power consumption by
    putting the device into a power-saving sleep mode.
  */
  restart --delay/Duration?=null -> none

/**
A channel is a cyclic datastructure that persists a sequence
  of distinct elements encoded in individual byte arrays.

A channel is identified by its $topic. If two channels share
  a topic, their elements will be stored together. It is
  possible to open any number of channels with the same
  topic, but only one of them can be a receiving channel
  opened using $(Channel.open --topic --receive).

The elements returned by calls to $Channel.receive must
  be acknowledged through calls to $Channel.acknowledge
  in order to not be received again the next time the
  channel is opened.
*/
class Channel extends ServiceResourceProxy:
  topic/string

  buffer_/ByteArray? := null
  cursor_/int? := null

  pages_/Deque := Deque
  buffered_/int := 0
  received_/int := 0
  acknowledged_/int := 0

  constructor.internal_ client/api.ArtemisClient handle/int --.topic:
    super client handle

  static open --topic/string --receive/bool=false -> Channel:
    client := artemis_client_
    if not client: throw "Artemis unavailable"
    handle := client.channel_open --topic=topic --receive=receive
    return Channel.internal_ client handle --topic=topic

  /**
  Whether this channel is empty.

  Receiving from an empty channel will cause $receive
    to return null. There can be multiple senders for
    a given channel, so it is possible to conclude that
    a channel is empty and get a non-null result from
    $receive because of an interleaved $send from
    another sender.

  Receiving from an non-empty channel will cause
    $receive to return a non-null byte array.
  */
  is_empty -> bool:
    if buffered_ > received_: return false
    receive_next_page_
    return cursor_ == null

  /**
  The number of elements currently buffered.
  */
  buffered -> int:
    return buffered_ - received_

  /**
  The current position.

  The position increases as elements are received
    through calls to $receive.
  */
  position -> ChannelPosition:
    pages := pages_
    if pages.is_empty:
      assert: received_ == 0
      return ChannelPosition.internal_ receive_next_page_
    else:
      first/ChannelPage_ := pages.first
      return ChannelPosition.internal_ first.position + received_

  /**
  Sends an $element of bytes to the channel.

  Variant of $(send element [--if_full]).

  The channel must not be full.
  */
  send element/ByteArray --copy/bool=true -> none:
    send element --if_full=: throw "OUT_OF_BOUNDS"

  /**
  Sends an $element of bytes to the channel.

  The element is added after any existing elements in
    the channel, so it will be returned from $receive
    only after those elements have been received.

  If the channel is full, the $if_full block is invoked
    with the $element.
  */
  send element/ByteArray [--if_full] -> none:
    sent := element
    if element is not ByteArraySlice_:
      // Even small external byte arrays are neutered
      // as part of sending them across the RPC boundary.
      // We avoid that behaviour by wrapping them in
      // a slice that is always copied. We could avoid
      // looking at the size and allocating the slice
      // if we had a quick way to tell if the element
      // was not external, but no such check exists.
      size := element.size
      sent = ByteArraySlice_ element 0 size
    success := (client_ as api.ArtemisClient).channel_send
        handle_
        sent
    if not success: if_full.call element

  /**
  Returns the next element in the channel or null if the
    channel has no elements.

  The returned element may be invalidated after having
    been acknowledged through a call to $acknowledge.
    If there is a chance that the element will be used
    after acknowledging it, the element must be copied
    prior to that.

  Throws an exception if the channel was found to be corrupt
    during the reading.
  */
  receive -> ByteArray?:
    while buffered_ == received_:
      receive_next_page_
      if not cursor_: return null
    next := receive_next_ buffer_
    received_++
    return next

  /**
  Acknowledges the handling of a received element.

  After acknowledging, old buffers that have been given through $receive may
    be reused and modified.

  The channel is allowed but not required to discard acknowledged elements.
    It may discard entries in bulk at a later time, and it thus possible to receive
    acknowledged elements again on later calls to $receive. This can only
    happen when a new receive channel is opened. A single channel never receives
    the same element multiple times.
  */
  acknowledge n/int=1 -> none:
    if n < 1: throw "Bad Argument"
    acknowledged := acknowledged_ + n
    received := received_
    if acknowledged > received: throw "OUT_OF_RANGE: $acknowledged > $received"
    acknowledged_ = acknowledged

    pages := pages_
    while not pages.is_empty:
      first/ChannelPage_ := pages.first
      count := first.count
      // Don't acknowledge the page until we're completely done with it.
      if acknowledged < count: break
      (client_ as api.ArtemisClient).channel_acknowledge handle_ first.position count
      pages.remove_first

      // Adjust the bookkeeping counts, so they represent the state
      // for the remaining pages.
      received -= count
      acknowledged -= count
      buffered_ -= count
      received_ = received
      acknowledged_ = acknowledged

  receive_next_page_ -> int:
    pages := pages_
    buffer := buffer_
    cursor_ = null

    // We have read the entire last page. We can reuse the
    // buffer if it has already been acked.
    peek := pages.size
    result := (client_ as api.ArtemisClient).channel_receive_page handle_
        --peek=peek
        --buffer=(peek == 0) ? buffer : null
    position := result[0]
    count := result[2]
    buffer_ = buffer = result[3]
    if count == 0: return position

    // Got another non-empty page. Wonderful!
    cursor_ = result[1]
    pages.add (ChannelPage_ --position=position --count=count)
    buffered_ += count
    return position

  receive_next_ buffer/ByteArray -> ByteArray?:
    cursor := cursor_
    from := cursor
    to := cursor

    // The elements in the buffer are encoded in
    // a sequence of 7 bit entries where the MSBs
    // of the bytes are zero. The first byte of
    // an element is different as it encodes only
    // 6 bits but has the MSB set to one.
    //
    //   element : 0b10xxxxxx (0b0yyyyyyy)+
    //
    // There will always be at least two encoding
    // bytes for an element because empty elements
    // are not allowed.
    //
    // The buffer contains a sequence of elements
    // and the bytes between the last element and
    // the end of the buffer page (EOF) have all
    // their bits set to one.
    //
    //   buffer : element* (0b11111111)* EOF
    //
    // Decoding is done in place, so the decoded
    // element ends up replacing the encoded one
    // in the buffer in the [$from, $to) range.
    // The decoded element is guaranteed to be
    // smaller, so $to never overtakes the $cursor.

    // Read the first byte and check if we have
    // reached the end. We will never be called
    // with the cursor pointing to the end of
    // the buffer.
    acc := buffer[cursor++]
    if acc == 0xff:
      cursor_ = null  // Read last entry.
      return null

    // Store the first 6 bits of the decoded
    // element in $acc.
    bits := 6
    acc &= 0x3f

    while true:
      while bits < 8:
        if cursor >= buffer.size:
          cursor_ = null  // Read last entry.
          return buffer[from..to]
        next := buffer[cursor]
        if (next & 0x80) != 0:
          // The MSB of the next byte is one, and the
          // current element thus ends.
          cursor_ = cursor
          return buffer[from..to]
        // The next byte has 7 more significant bits
        // for us, so we extend $acc with them.
        acc |= (next << bits)
        bits += 7
        cursor++
      // We have the necessary 8 bits, so we can
      // construct another byte of the decoded
      // element from the least significant bits
      // of $acc.
      buffer[to++] = (acc & 0xff)
      acc >>= 8
      bits -= 8

/**
A position in a channel is used to identify an element
  after having sent it to the channel.

The positions can be used to de-duplicate elements that
  are received more than once due to lost acknowledgements.

The positions can also be used to find elements that were
  lost due to corruption and thus never received. Such
  elements will show up as gaps in the position sequence.

The channels keep track of the position of all elements
  they hold and it is possible to find the position of
  the next element returned from $Channel.receive by
  using $Channel.position.
*/
class ChannelPosition implements Comparable:
  value/int
  constructor.internal_ value/int:
    this.value = value & api.ArtemisService.CHANNEL_POSITION_MASK

  stringify -> string:
    return "$(%08x value)"

  operator + n/int -> ChannelPosition:
    return ChannelPosition.internal_ value + n

  operator - n/int -> ChannelPosition:
    return ChannelPosition.internal_ value - n

  operator == other/any -> bool:
    return other is ChannelPosition and value == other.value

  operator < other/ChannelPosition -> bool:
    return (api.ArtemisService.channel_position_compare value other.value) < 0

  operator <= other/ChannelPosition -> bool:
    return (api.ArtemisService.channel_position_compare value other.value) <= 0

  operator > other/ChannelPosition -> bool:
    return (api.ArtemisService.channel_position_compare value other.value) > 0

  operator >= other/ChannelPosition -> bool:
    return (api.ArtemisService.channel_position_compare value other.value) >= 0

  /**
  Compares this position to $other.

  Returns -1, 0, or 1 if the $this is less than, equal to, or
    greater than $other, respectively.

  Positions wrap around when they reach the representable limit
    while still supporting comparison. If positions are close
    together, then they use normal comparison. However, when they
    are far apart, then they have wrapped around which means that
    the smaller number is considered greater than the larger number.
  */
  compare_to other/ChannelPosition -> int:
    return api.ArtemisService.channel_position_compare value other.value

  /**
  Variant of $(compare_to other).

  Calls $if_equal if this and $other are equal. Then returns the
    result of the call.
  */
  compare_to other/ChannelPosition [--if_equal] -> int:
    result := api.ArtemisService.channel_position_compare value other.value
    if result == 0: result = if_equal.call
    return result

class ChannelPage_:
  position/int
  count/int
  constructor --.position --.count:
