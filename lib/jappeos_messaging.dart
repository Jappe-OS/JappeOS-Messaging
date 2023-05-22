//  JappeOS-Messaging, A pipe messaging system for JappeOS/Linux.
//  Copyright (C) 2023  Jappe02
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU Affero General Public License as
//  published by the Free Software Foundation, either version 3 of the
//  License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU Affero General Public License for more details.
//
//  You should have received a copy of the GNU Affero General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:convert';
import 'dart:io';

import 'package:event/event.dart';

/// The core pipe message manager for JappeOS. Helps the sending of
/// messages to the `jappeos_core` process on Linux.
/// 
/// To send a message, use the [send] function, if you want to listen
/// for messages, subscribe to the [receive] event using .subscribe.
/// 
/// [init] initializes the [CoreMessageMan], making it possible to
/// receive messages from other processes. `setReceivePipePath` is
/// an optional field, if null, uses the defualt value. [init]
/// should be called when the application starts, in the `main` function.
/// 
/// WARNING: This is meant to be able to work on Linux only, may work
/// on other operating systems, but it is not tested.
class CoreMessageMan {
  // Current pipe message receive directory location.
  static String? _dir;

  /// Initializes the pipe message system. If [setReceivePipePath] is null,
  /// it will default to "${Platform.executable}/pipes".
  static void init([String? setReceivePipePath]) async {
    _dir = setReceivePipePath ?? "${Platform.executable}/pipes";

    // Create a named pipe (FIFO) for receiving messages
    await Process.run('mkfifo', [_dir!]);
    final receivePipe = File(_dir!).openRead();
    await for (final data in receivePipe) {
      receive.broadcast(Value(utf8.decode(data).trim()));
    }
  }

  /// Send message to target pipe. The message is a String type.
  static void send(String target) {
    // Open the send pipe for writing
    final sendPipe = File(target).openWrite(mode: FileMode.append);
    sendPipe.writeln(target);

    // Close the send pipe
    sendPipe.close();
  }

  /// An event that is fired when a message is received. The received message is a String.
  static Event<Value<String>> receive = Event<Value<String>>();

  /// Get the current pipe path set in the [init] function.
  static String? getPipePath() => _dir;
}