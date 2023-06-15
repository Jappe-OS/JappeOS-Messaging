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

import 'dart:io';
import 'package:event/event.dart';

/// Use this class to send/receive messages between processes
/// using the JappeOS messaging system.
class JappeOSMessaging {
  /// Holds a list of clients connected to this instance.
  static final List<Socket> _clients = [];

  /// Initializes the messaging system with a `port` to use.
  /// This makes it possible for the "server" (this process)
  /// to send and receive [Message]s using the other methods
  /// provided by this class.
  static void init(int port) {
    ServerSocket.bind('localhost', port).then((serverSocket) {
      // Handle successful server startup. >>
      print('Server listening on ${serverSocket.address}:${serverSocket.port}');

      // Handle connection of a client.
      serverSocket.listen((clientSocket) {
        print('Client connected: ${clientSocket.remoteAddress}:${clientSocket.remotePort}');
        _clients.add(clientSocket);

        // Listen for messages from the client & invoke the 'receive' event.
        clientSocket.listen((data) {
          var request = String.fromCharCodes(data).trim();
          print('Received request from client (${clientSocket.remoteAddress}:${clientSocket.remotePort}): $request');
          receive.broadcast(Message.fromString(request));
        }, onDone: () {
          _handleClientDisconnection(clientSocket);
        });
      });
    }).catchError((error) {
      // Handle failed server startup. >>
      print('Failed to start server: $error');
    });
  }

  /// Handle the disconnection of a client, a client needs
  /// to connect to send messages.
  static void _handleClientDisconnection(Socket clientSocket) {
    print('Client disconnected: ${clientSocket.remoteAddress}:${clientSocket.remotePort}');
    _clients.remove(clientSocket);
  }

  /// Stops the "server" (this process) and cleans everything up.
  /// After this method is called, [Message]s can no longer
  /// be sent or received.
  static void clean() async {
    for (Socket clientSocket in _clients) {
      clientSocket.flush();
      clientSocket.close();
    }
    _clients.clear();
  }

  /// Sends a [Message] object to another process listening on
  /// the `port` port. A message can contain a lot of data,
  /// see: [Message].
  static Future<MessageOperationResult> send(Message msg, int port) {
    Socket.connect('localhost', port).then((socket) {
      // Connect, Write, Disconnect.
      socket.write(msg.toString());
      socket.flush();
      socket.close();
      print('Message sent to localhost:$port');
      return Future.value(MessageOperationResult.success());
    }).catchError((error) {
      print('Failed to send message: $error');
      return Future.value(MessageOperationResult.error(error));
    });

    // If nothing is returned here yet, it is obviously an error.
    return Future.value(MessageOperationResult.error(null));
  }

  /// An [Event] that can be listened to. Listen for [Message]s
  /// sent to this instance, a message can contain a lot of data,
  /// see: [Message]. For the use of the event system, see: [Event].
  static final receive = Event<Message>();
}

/// A message that can be first sent, then received somewhere else.
/// See [JappeOSMessaging.send] and [JappeOSMessaging.receive] for
/// using the messaging system to send/receive messages between
/// separate processes.
class Message extends EventArgs {
  /// The name/ID of the message to be sent, should not contain spaces.
  /// This name should also be unique, to be sure, numbers can be used
  /// as a prefix/suffix if needed.
  String name;

  /// The arguments of the message, can be left empty. Key & Value.
  /// These args are used to transport data alongside the message.
  Map<String, String> args;

  /// Converts any [String] to a new [Message] object.
  static Message fromString(String str) {
    Message result = Message(_getSubstringBeforeFirstSpace(str), {});

    var pairs = str.replaceFirst(result.name, "").trim().split(';');
    for (var pair in pairs) {
      var keyValue = pair.split(':');
      if (keyValue.length == 2) {
        var key = keyValue[0].replaceAll('"', '').trim();
        var value = keyValue[1].replaceAll(RegExp(r'(?<!\\)"'), '').replaceAll(r'\"', '"').trim();
        result.args[key] = value;
      }
    }

    return result;
  }

  /// Converts this [Message] object to a [String] type.
  @override
  String toString() {
    String result = "${validateName(name)} ";

    args.forEach((key, value) {
      result += '"$key":"${value.replaceAll('"', r'\"')}";';
    });

    return result;
  }

  /// Fixes invalid message names.
  static String validateName(String str) {
    return str.replaceAll(" ", "-");
  }

  /// Get all text before the first " " letter in a [String].
  static String _getSubstringBeforeFirstSpace(String input) {
    List<String> parts = input.split(' ');
    if (parts.isNotEmpty) {
      return parts.first;
    }
    return '';
  }

  /// Contruct a [Message] object containing a required name,
  /// the name should not have any blank spaces. `args` can
  /// be empty, not null.
  Message(this.name, this.args);
}

/// The result of a messaging operation like send().
class MessageOperationResult {
  /// Whether the operation was successful or not. Cannot be null.
  final bool success;

  /// Other info. Can be displayed as a message to a user to give more
  /// information about the error. A successful operation does not need this.
  /// Can be null if no info was provided.
  final String? info;

  /// Construct a successful operation, no additional info can be added.
  factory MessageOperationResult.success() {
    return MessageOperationResult._(true, null);
  }

  /// Contruct a operation result that resulted in an error. Additional info
  /// can be provided, if any.
  factory MessageOperationResult.error(String? info) {
    return MessageOperationResult._(false, null);
  }

  /// Private contructor to construct a [MessageOperationResult].
  MessageOperationResult._(this.success, this.info);
}
