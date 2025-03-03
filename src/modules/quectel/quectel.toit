// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.

import net
import net.udp as udp
import net.tcp as tcp
import log
import monitor
import uart

import system.base.network show CloseableNetwork

import ...base.at as at
import ...base.base
import ...base.cellular
import ...base.exceptions
import ...location show Location GnssLocation

CONNECTED_STATE_  ::= 1 << 0
READ_STATE_       ::= 1 << 1
CLOSE_STATE_      ::= 1 << 2

TIMEOUT_QIOPEN     ::= Duration --s=150
TIMEOUT_QIRD       ::= Duration --s=15
TIMEOUT_QISEND     ::= Duration --s=15
TIMEOUT_CLOSE_WAIT ::= Duration --s=30

monitor SocketState_:
  state_/int := 0
  dirty_/bool := false

  wait_for state --error_state=CLOSE_STATE_:
    bits := (state | error_state)
    await: state_ & bits != 0
    dirty_ = false
    return state_ & bits

  set_state state:
    dirty_ = true
    state_ |= state

  clear state:
    // Guard against clearing inread state (e.g. if state was updated
    // in between wait_for and clear).
    if not dirty_:
      state_ &= ~state



abstract class Socket_:
  static ERROR_OK_                        ::= 0
  static ERROR_MEMORY_ALLOCATION_FAILED_  ::= 553
  static ERROR_OPERATION_BUSY_            ::= 568
  static ERROR_OPERATION_NOT_ALLOWED_     ::= 572

  static SOCKET_CLOSED_                   ::= "SOCKET_CLOSED"

  state_ ::= SocketState_
  should_pdp_deact_ := false
  cellular_/QuectelCellular ::= ?
  id_ := ?

  error_ := 0

  constructor .cellular_ .id_:

  pdp_deact_:
    should_pdp_deact_ = true

  /**
  Closed from remote
  */
  close-wait:
    closed_
    id := id_
    id_ = null // Drop the instance reference here to allow for socket closed exceptions.
    task --background ::
      sleep TIMEOUT_CLOSE_WAIT
      socket_call:
        it.set "+QICLOSE" [id, 0]
      cellular_.sockets_.remove id

  closed_:
    state_.set_state CLOSE_STATE_

  abstract close

  get_id_:
    if not id_: throw SOCKET-CLOSED_
    return id_

  /**
  Calls the given $block.
  Captures exceptions and translates them to socket-related errors.
  */
  socket_call [block]:
    // Ensure no other socket call can come in between.
    cellular_.at_.do: | session/at.Session |
      e := catch:
        return block.call session
      throw (last_error_ session e)
    unreachable

  /**
  Returns the latest socket error (even if OK).
  */
  last_error_ cellular/at.Session original_error/string="" -> Exception:
    if original_error == SOCKET-CLOSED_:
      catch --trace: throw original-error
      throw (UnavailableException original_error)
    res := cellular.action "+QIGETERROR"
    error := res.last[0]
    error_message := res.last[1]
    if error == ERROR_OK_:
      throw (UnavailableException original_error)
    if error == ERROR_OPERATION_BUSY_:
      throw (UnavailableException error_message)
    if error == ERROR_MEMORY_ALLOCATION_FAILED_:
      throw (UnavailableException error_message)
    if error == ERROR_OPERATION_NOT_ALLOWED_:
      throw (UnavailableException error_message)
    throw (UnknownException "SOCKET ERROR $error ($error_message - $original_error)")

class TcpSocket extends Socket_ implements tcp.Socket:
  static MAX_SIZE_ ::= 1460

  peer_address/net.SocketAddress ::= ?

  // TODO(kasper): Deprecated. Remove.
  set_no_delay value/bool:
    no_delay = value

  no_delay -> bool:
    return false

  no_delay= value/bool -> none:
    // Not supported on BG96 (let's assume always disabled).

  constructor cellular id .peer_address:
    super cellular id

  initiate_connection_:
    socket_call:
      it.set "+QIOPEN" --timeout=TIMEOUT_QIOPEN [
        cellular_.cid_,
        get_id_,
        "TCP",
        peer_address.ip.stringify,
        peer_address.port
      ]

  local_address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect_:
    state := cellular_.wait_for_urc_: state_.wait_for CONNECTED_STATE_
    if state & CONNECTED_STATE_ != 0: return
    throw "CONNECT_FAILED: $error_"

  read -> ByteArray?:
    while true:
      state := cellular_.wait_for_urc_: state_.wait_for READ_STATE_
      if state & CLOSE_STATE_ != 0:
        return null
      else if state & READ_STATE_ != 0:
        r/at.Result := socket_call: | session/at.Session |
          session.set "+QIRD" --timeout=TIMEOUT_QIRD [get_id_, 1500]
        out := r.single
        if out[0] > 0:
          //cellular_.logger.debug "<- <$(out[1].size) bytes>"
          return out[1]
        state_.clear READ_STATE_
      else:
        throw "SOCKET ERROR"

  write data from/int=0 to/int=data.size -> int:
    if to - from > MAX_SIZE_:
      to = from + MAX_SIZE_

    data = data[from..to]

    e := catch --unwind=(: it is not UnavailableException):
      // Give processing time to other tasks, to avoid busy write-loop that starves readings.
      yield
      socket_call:
        it.set "+QISEND" [get_id_, data.size]
            --timeout=TIMEOUT_QISEND
            --data=data
      return data.size

    // Buffer full, wait for buffer to be drained.
    sleep --ms=100
    return 0

  /**
  Closes the socket for write. The socket is still be able to read incoming data.
  */
  close_write:
    throw "UNSUPPORTED"

  // Immediately close the socket and release any resources associated.
  close:
    if id_:
      id := id_
      closed_
      id_ = null
      try:
        cellular_.at_.do:
          if should_pdp_deact_: it.send (QIDEACT id)
          if not it.is_closed:
            it.send
              QICLOSE id Duration.ZERO
      finally:
        cellular_.sockets_.remove id

  mtu -> int:
    // From spec, +QISEND only allows sending 1460 bytes at a time.
    return 1460

class UdpSocket extends Socket_ implements udp.Socket:
  remote_address_ := null

  constructor cellular/QuectelCellular id/int:
    super cellular id

  initiate-connection_ port/int:
    socket_call:
      it.set "+QIOPEN" --timeout=TIMEOUT_QIOPEN [
        cellular_.cid_,
        get_id_,
        "UDP SERVICE",
        "127.0.0.1",
        0,
        port,
        0,
      ]

  local_address -> net.SocketAddress:
    return net.SocketAddress
      net.IpAddress.parse "127.0.0.1"
      0

  connect address/net.SocketAddress:
    remote_address_ = address

  write data/ByteArray from=0 to=data.size -> int:
    if not remote_address_: throw "NOT_CONNECTED"
    if from != 0 or to != data.size: data = data[from..to]
    return send_ remote_address_ data

  read -> ByteArray?:
    msg := receive
    if not msg: return null
    return msg.data

  send datagram/udp.Datagram -> int:
    return send_ datagram.address datagram.data

  send_ address data -> int:
    if data.size > mtu: throw "PAYLOAD_TO_LARGE"
    res := socket_call:
      it.set "+QISEND" [get_id_, data.size, address.ip.stringify, address.port]
          --timeout=TIMEOUT_QISEND
          --data=data
    return data.size

  receive -> udp.Datagram?:
    while true:
      state := state_.wait_for READ_STATE_
      if state & CLOSE_STATE_ != 0:
        return null
      else if state & READ_STATE_ != 0:
        res := socket_call: (it.set "+QIRD" --timeout=TIMEOUT_QIRD [get_id_]).single
        if res[0] > 0:
          return udp.Datagram
            res[3]
            net.SocketAddress
              net.IpAddress.parse res[1]
              res[2]

        state_.clear READ_STATE_
      else:
        throw "SOCKET ERROR"

  close:
    if id_:
      cellular_.at_.do:
        if not it.is_closed:
          it.send
            QICLOSE id_ Duration.ZERO
      closed_
      cellular_.sockets_.remove id_
      id_ = null

  mtu -> int:
    // From spec, +QISEND only allows sending 1460 bytes at a time.
    return 1460

  broadcast -> bool: return false

  broadcast= value/bool: throw "BROADCAST_UNSUPPORTED"

/**
Base driver for Quectel Cellular devices, communicating over CAT-NB1 and/or CAT-M1.
*/
abstract class QuectelCellular extends CellularBase implements Gnss:
  resolve_/monitor.Latch? := null
  gnss_users_ := 0

  /**
  Called when the driver should reset.
  */
  abstract on_reset session/at.Session

  constructor
      uart/uart.Port
      --logger/log.Logger
      --uart_baud_rates/List
      --use_psm:
    at_session := configure_at_ uart logger

    super uart at_session
      --logger=logger
      --constants=QuectelConstants
      --uart_baud_rates=uart_baud_rates
      --use_psm=use_psm

    at_session.register_urc "+QIOPEN":: | args |
      sockets_.get args[0]
        --if_present=: | socket/Socket_ |
          if args[1] == 0:
            // Success.
            if socket.error_ == 0:
              socket.state_.set_state CONNECTED_STATE_
            else:
              // The connection was aborted.
              logger.warn "Socket has errors ($socket.error_), closing"
              socket.close-wait
          else:
            // Failure
            logger.warn "Open failed with error $args[1]"
            socket.error_ = args[1]
            socket.close-wait
        --if-absent=: logger.warn "Socket $args[0] not found"

    at_session.register_urc "+QIURC"::
      if it[0] == "dnsgip":
        if it[1] is int and it[1] != 0:
          if resolve_: resolve_.set --exception "RESOLVE FAILED: $it[1]"
        else if it[1] is string:
          if resolve_: resolve_.set it[1]
      else if it[0] == "recv":
        sockets_.get it[1]
          --if_present=: it.state_.set_state READ_STATE_
      else if it[0] == "closed":
        sockets_.get it[1]
          --if_present=: | socket/Socket_ |
            socket.close-wait
      else if it[0] == "pdpdeact":
        sockets_.get it[1]
          --if_present=: | socket/Socket_ |
            it.pdp_deact_
            it.closed_

  static configure_at_ uart logger -> at.Session:
    session := at.Session uart uart
      --logger=logger
      --data_marker='>'
      --command_delay=Duration --ms=20

    session.add_ok_termination "SEND OK"
    session.add_error_termination "SEND FAIL"
    session.add_error_termination "+CME ERROR"
    session.add_error_termination "+CMS ERROR"

    session.add_response_parser "+QIRD" :: | reader |
      line := reader.read_bytes_until '\r'
      parts := at.parse_response line
      if parts[0] == 0:
        [0]
      else:
        reader.skip 1  // Skip '\n'.
        session.logger_.debug "<- +QIRD $parts"
        parts.add (reader.read_bytes parts[0])
        parts

    // Custom parsing as ICCID is returned as integer but larger than 64bit.
    session.add_response_parser "+QCCID" :: | reader |
      iccid := reader.read_until session.s3
      [iccid]  // Return value.

    session.add_response_parser "+QIND" :: | reader |
      [reader.read_until session.s3]

    session.add_response_parser "+QIGETERROR" :: | reader |
      line := reader.read_bytes_until session.s3
      values := at.parse_response line --plain  // Return value.
      values[0] = int.parse values[0]
      values

    return session

  close:
    try:
      sockets_.values.do: | socket/Socket_ |
        socket.close
      2.repeat: | attempt/int |
        catch: with_timeout --ms=1_500: at_.do: | session/at.Session |
          if not session.is_closed:
            if use_psm and not failed_to_connect and not is_lte_connection_:
              session.set "+QCFG" ["psm/enter", 1]
            else:
              session.send QPOWD
          return
        // If the chip was recently rebooted, wait for it to be responsive before
        // communicating with it again. Only do this once.
        if attempt == 0: wait_for_ready
    finally:
      at_session_.close
      uart_.close

  iccid:
    r := at_.do: it.action "+QCCID"
    return r.last[0]

  rats_to_scan_sequence_ rats/List? -> string:
    if not rats: return "00"

    res := ""
    rats.do: | rat |
      if rat == RAT_GSM:
        res += "01"
      else if rat == RAT_LTE_M:
        res += "02"
      else if rat == RAT_NB_IOT:
        res += "03"
    return res.is_empty ? "00" : res

  rats_to_scan_mode_ rats/List? -> int:
    if not rats: return 0  // Automatic.

    if rats.contains RAT_GSM:
      if rats.contains RAT_LTE_M or rats.contains RAT_NB_IOT:
        return 0
      else:
        return 1  // GSM only.

    if rats.contains RAT_LTE_M or rats.contains RAT_NB_IOT:
      return 3  // LTE only.

    return 0

  support_gsm_ -> bool:
    return true

  configure apn/string --bands=null --rats=null:
    at_.do: | session/at.Session |
      // Set connection arguments.

      while true:
        should_reboot := false
        enter_configuration_mode_ session

        // LTE only.
        session.set "+QCFG" ["nwscanmode", rats_to_scan_mode_ rats]
        // M1 only (M1 & NB1 is giving very slow connects).
        session.set "+QCFG" ["iotopmode", 0]
        // M1 -> NB1 (default).
        session.action "+QCFG=\"nwscanseq\",$(rats_to_scan_sequence_ rats)"
        // Only use GSM data service domain.
        session.action "+QCFG=\"servicedomain\",1"
        // Enable PSM URCs.
        session.set "+QCFG" ["psm/urc", 1]
        // Enable URC on uart1.
        session.set "+QURCCFG" ["urcport", "uart1"]
        session.set "+CTZU" [1]

        session.set "+IFC" [0, 0]

        if bands:
          mask := 0
          bands.do: mask |= 1 << (it - 1)
          set_band_mask_ session mask

        if (get_apn_ session) != apn:
          set_apn_ session apn
          // TODO(kasper): It is unclear why we need to reboot here. The +CGDCONT
          // description in the Quectel manuals do not indicate that we should.
          should_reboot = true

        if should_reboot:
          reboot_ session
          continue

        configure_psm_ session --enable=use_psm
        set_up_psm_urc_handler_ session
        break

  configure_psm_ session/at.Session --enable/bool --periodic_tau/string="00111111":
    psm_target := enable ? 1 : 0
    value := session.read "+CPSMS"

    if value.last[0] == psm_target: return

    parameters := enable ? [psm_target, null, null, periodic_tau, "00000000"] : [psm_target]
    session.set "+CPSMS" parameters

  set_band_mask_ session/at.Session mask/int:
    // Set mask for both m1 and nbiot.
    hex_mask:= mask.stringify 16
    session.action "+QCFG=\"band\",0,$hex_mask,$hex_mask"

  set_up_psm_urc_handler_ session/at.Session:
    // The modem sometimes enters PSM unexpectedly. If a connection is
    // already established, then we need to restart to reestablish the
    // connection.
    lambda := :: throw "unexpected PSM enter"
    // We sometimes end up registering the +QPSMTIMER URC handler more
    // than once. Don't turn that into a problem.
    catch: session.register_urc "+QPSMTIMER" lambda

  connect_psm -> none:
    at_.do: | session/at.Session |
      set_up_psm_urc_handler_ session
    super

  network_interface -> net.Interface:
    return Interface_ network_name this

  // Override disable_radio_, as the SIM cannot be accessed unless airplane mode is used.
  disable_radio_ session/at.Session:
    session.send CFUN.airplane

  reset:
    detach
    // Factory reset.
    at_.do: it.action "&F"

  reboot_ session/at.Session:
    on_reset session
    // Rebooting the module should get it back into a ready state. We avoid
    // calling $wait_for_ready_ because it flips the power on, which is too
    // heavy an operation.
    5.repeat: if select_baud_ session: return
    wait_for_ready_ session

  set_baud_rate_ session/at.Session baud_rate:
    // Set baud rate and persist it.
    session.action "+IPR=$baud_rate;&W"
    uart_.baud_rate = baud_rate
    sleep --ms=100

  gnss_start:
    at_.do: gnss_eval_ it
    gnss_users_++
    at_.do: gnss_eval_ it

  gnss_location -> GnssLocation?:
    at_.do: | session/at.Session |
      gnss_eval_ session
      if gnss_users_ == 0: return null
      catch --unwind=(: it != at.COMMAND_TIMEOUT_ERROR and not it.contains "Not fixed now"):
        response := (session.set "+QGPSLOC" [2]).last
        latitude/float := response[1]
        longitude/float := response[2]
        horizontal_accuracy/float := response[3]
        altitude/float := response[4]
        return GnssLocation
            Location latitude longitude
            altitude
            Time.now
            horizontal_accuracy
            1.0  // vertical_accuracy
      return null
    unreachable

  gnss_stop:
    gnss_users_--
    at_.do: gnss_eval_ it

  gnss_eval_ session/at.Session -> none:
    state/int? ::= gnss_state_ session
    if not state: return
    if gnss_users_ > 0:
      if state != 1:
        session.set "+QGPS" [1, 255]
    else if state != 0:
      session.action "+QGPSEND"

  gnss_state_ session/at.Session -> int?:
    3.repeat:
      catch:
        state := (session.read "+QGPS").last
        return state[0]
      // We sometimes see the QGPS read time out, so we try to
      // work around that by trying more than once. We make sure
      // we can read from the UART by caling $select_baud_.
      select_baud_ session
    return null

class QuectelConstants implements Constants:
  RatCatM1 -> int: return 8

class Interface_ extends CloseableNetwork implements net.Interface:
  static FREE_PORT_RANGE ::= 1 << 14

  name/string
  cellular_/QuectelCellular
  resolve_mutex_ ::= monitor.Mutex
  free_port_ := 0

  constructor .name .cellular_:

  resolve host/string -> List:
    // First try parsing it as an ip.
    catch:
      return [net.IpAddress.parse host]

    // The DNS resolution is async, so we have to serialize
    // the requests and take them one by one.
    resolve_mutex_.do:
      cellular_.resolve_ = monitor.Latch
      try:
        cellular_.at_.do:
          it.send (QIDNSGIP.async host)
        cellular_.wait_for_urc_:
          result := cellular_.resolve_.get
          return [net.IpAddress.parse result]
      finally:
        cellular_.resolve_ = null
    unreachable

  udp_open -> udp.Socket:
    return udp_open --port=null

  udp_open --port/int? -> udp.Socket:
    id := socket_id_
    if not port or port == 0:
      // Best effort for rolling a free port.
      port = FREE_PORT_RANGE + free_port_++ % FREE_PORT_RANGE
    socket := UdpSocket cellular_ id
    cellular_.sockets_.update id --if_absent=(: socket): throw "socket already exists"

    socket.initiate_connection_ port // Moved the initiation of the socket to after the id is added to the sockets.
                                     // Previously, the modem could respond before the id was added to the sockets,

    return socket

  tcp_connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp_connect
        net.SocketAddress ips[0] port

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    id := socket_id_
    socket := TcpSocket cellular_ id address
    cellular_.sockets_.update id --if_absent=(: socket): throw "socket already exists"

    socket.initiate_connection_ // Moved the initiation of the socket to after the id is added to the sockets.
                                // Previously, the modem could respond before the id was added to the sockets,

    catch --unwind=(: socket.error_ = 1; true): socket.connect_

    return socket

  tcp_listen port/int -> tcp.ServerSocket:
    throw "UNIMPLEMENTED"

  socket_id_ -> int:
    12.repeat:
      if not cellular_.sockets_.contains it: return it
    throw
      ResourceExhaustedException "no more sockets available"

  address -> net.IpAddress:
    unreachable

  is_closed -> bool:
    // TODO(kasper): Implement this?
    return false

  close_:
    // TODO(kasper): Implement this?

class QIDNSGIP extends at.Command:
  static TIMEOUT ::= Duration --s=70

  constructor.async host/string:
    super.set "+QIDNSGIP" --parameters=[1, host] --timeout=TIMEOUT

class QPOWD extends at.Command:
  static TIMEOUT ::= Duration --s=40

  constructor:
    super.set "+QPOWD" --parameters=[0] --timeout=TIMEOUT

class QICLOSE extends at.Command:
  constructor id/int timeout/Duration:
    super.set "+QICLOSE" --parameters=[id, timeout.in_s] --timeout=at.Command.DEFAULT_TIMEOUT + timeout

class QIACT extends at.Command:
  static TIMEOUT ::= Duration --s=150
  constructor id/int:
    super.set "+QIACT" --parameters=[id] --timeout=TIMEOUT

class QIDEACT extends at.Command:
  static TIMEOUT ::= Duration --s=40
  constructor id/int:
    super.set "+QIDEACT" --parameters=[id] --timeout=TIMEOUT

class QICFG extends at.Command:
  /**
    $idle_time in range 1-120, unit minutes.
    $interval_time in range 25-100, unit seconds.
    $probe_count in range 3-10.
  */
  constructor.keepalive --enable/bool --idle_time/int=1 --interval_time/int=30 --probe_count=3:
    ps := enable ? ["tcp/keepalive", 1, idle_time, interval_time, probe_count] : ["tcp/keepalive", 0]
    super.set "+QICFG" --parameters=ps

class QNWINFO extends at.Command:
  constructor:
    super.action "+QNWINFO"