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

// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'dart:io';

import 'package:event/event.dart';

/// ARGS: "u:": Username; "p:": Password;
///
/// EXAMPLE: ".. + "u:My Namep:My Password""
///
/// RECEIVES_CALLBACK: false
const JMSG_COREPRCSS_MSG_LOGIN = "login ";

/// ARGS:*
///
/// EXAMPLE: ".."
///
/// RECEIVES_CALLBACK: false
const JMSG_COREPRCSS_MSG_LOGOUT = "logout";

/// ARGS: "$from": The current receive pipe path;
///
/// EXAMPLE: ".. $from/path/to/receive/pipe"
///
/// RECEIVES_CALLBACK: true
///
/// CALLBACK_ARGS: "v:" The value (bool);
///
/// CALLBACK_EXAMPLE: ".. v:true"
const JMSG_COREPRCSS_MSG_RECV_LOGGEDIN = "logged-in ";

/// ARGS:*
///
/// EXAMPLE: ".."
///
/// RECEIVES_CALLBACK: false
const JMSG_COREPRCSS_MSG_SHUTDOWN = "shutdown";

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
      String message = utf8.decode(data).trim();
      String first = message.substring(0, message.indexOf('\$'));
      Map<String, String> args = {};

      RegExp regex = RegExp(r'\$(.*?)\$');
      Iterable<RegExpMatch> matches = regex.allMatches(message);

      for (RegExpMatch match in matches) {
        String? key = match.group(1);
        int start = match.end;
        int end = (matches.elementAt(matches.toList().indexOf(match) + 1).start);
        String value = message.substring(start, end).trim();

        args[key ?? "NULL"] = value;
      }

      receive.broadcast(Message(first, args));
    }
  }

  /// Send message to target pipe. The message is a String type.
  static void send(String target, Message message) {
    // Open the send pipe for writing
    final sendPipe = File(target).openWrite(mode: FileMode.append);

    String finalMsg = message.message;
    if (finalMsg.substring(finalMsg.length - 1) != " ") finalMsg += " ";
    message.args.forEach((key, value) {
      finalMsg += r"$" + key + r"$";
      finalMsg += value;
    });

    sendPipe.writeln(finalMsg + r"$end");

    // Close the send pipe
    sendPipe.close();
  }

  /// An event that is fired when a message is received. The received message is a String.
  static Event<Message> receive = Event<Message>();

  /// Get the current pipe path set in the [init] function.
  static String? getPipePath() => _dir;
}

/// A message that can be sent and received.
class Message extends EventArgs {
  Message(this.message, this.args);

  /// The message.
  final String message;

  /// Message args; key = The id, value = The value of the arg.
  final Map<String, String> args;
}
