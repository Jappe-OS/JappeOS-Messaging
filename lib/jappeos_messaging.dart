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
import 'dart:typed_data';
import 'package:event/event.dart';

/// Use this class to send/receive messages between processes
/// using the JappeOS messaging system.
/// TODO: Double check MessageAddress usage in code.
class MessagingPipe {
  /// Holds a static list of all [MessagingPipe] instances created in this app.
  static final List<String> _instances = [];

  /// Return the static list of all [MessagingPipe] instances created in this app.
  static List<String> get instances => _instances;

  /// A private constructor to construct with name.
  MessagingPipe._(String name) {
    _name = name;
  }

  /// The server of this messaging pipe.
  late ServerSocket _serverSocket;

  /// Holds a list of clients connected to this instance.
  final List<Socket> _clientsConnected = [];

  /// Holds a list of clients this instance has connected to.
  ///
  /// [Socket] is the socket this intance is connected to,
  /// while [int] is the target port it was first connected to.
  final List<Socket> _connectedTo = [];

  /// The name of this pipe.
  late String _name;

  /// Get the name of this pipe.
  String get name => _name;

  /// Get the address of this pipe.
  String get address => _serverSocket.address.address;

  /// Get a list of addresses of remote instances connected to this instance.
  List<String> get connectedFromAddresses => _clientsConnected.map((socket) => socket.remoteAddress.address).toList();

  /// Get a list of addresses that this instance is connected to.
  List<String> get connectedToAddresses => _connectedTo.map((socket) => socket.remoteAddress.address).toList();

  /// Initializes the messaging system with a `name` to use.
  /// This makes it possible for the "server" (this process)
  /// to send and receive [Message]s using the other methods
  /// provided by this class.
  ///
  /// [MessagingPipe] will return null if an error has occurred.
  ///
  /// NOTE: Remember to call [clean] after using this [MessagingPipe] to clean up all resources.
  static Future<MessagingPipe?> init(String name, [bool useCustomDirectory = false]) async {
    if (!Platform.isLinux) {
      throw Exception("Unsupported platform! 'Platform.isLinux' returned false.");
    } else if (_instances.contains(name)) {
      throw Exception("A messaging pipe with the name '$name' is already initialised!");
    }

    MessagingPipe thisObj = MessagingPipe._(name);
    InternetAddress address;
    var runtimeDir = Platform.environment['XDG_RUNTIME_DIR'];

    if (useCustomDirectory) {
      address = InternetAddress(name, type: InternetAddressType.unix);
    } else {
      if (runtimeDir == null) throw Exception("The environment variable 'XDG_RUNTIME_DIR' returned null.");
      address = InternetAddress('$runtimeDir/$name', type: InternetAddressType.unix);
    }

    try {
      thisObj._serverSocket = await ServerSocket.bind(address, 0);
    } catch (e) {
      // Handle failed server startup. >>
      thisObj.clean();
      print('Failed to start server: $e');
      return Future.value(null);
    }

    // Handle successful server startup. >>
    print('Server listening on: ${address.address}');

    // Add this instance.
    _instances.add(address.address);

    // Handle connection of a client that is connecting to this instance.
    thisObj._serverSocket.listen((clientSocket) async {
      print(
          'New remote client connected: ${clientSocket.remoteAddress.address} Test: (remoteaddr: ${clientSocket.remoteAddress}, raw: ${clientSocket.remoteAddress.rawAddress})');
      thisObj._clientsConnected.add(clientSocket);

      // Start listening for messages from the client & invoke the 'receive' event.
      clientSocket.listen((data) async {
        thisObj._handleClientData(clientSocket, data);
      }, onDone: () async {
        // When the client disconnects.
        thisObj._handleClientDisconnection(clientSocket);
      });
    });

    return Future.value(thisObj);
  }

  /// Handle data received from a client connected to this instance.
  void _handleClientData(Socket clientSocket, Uint8List data) async {
    var request = String.fromCharCodes(data).trim();
    print('Received request from remote instance (${clientSocket.remoteAddress.address}): $request');
    receiveAll.broadcast(MessageEventArgs(clientSocket, Message.fromString(request)));
  }

  /// Handle the disconnection of a client coonected to this instance,
  /// a client needs to connect first to send messages.
  void _handleClientDisconnection(Socket clientSocket) async {
    print('Client disconnected: ${clientSocket.remoteAddress.address}');
    _clientsConnected.remove(clientSocket);
  }

  /// Stops this "server" (this instance) and cleans everything up.
  /// After this method is called, [Message]s can no longer
  /// be sent or received from/to this instance.
  void clean() async {
    receiveAll.unsubscribeAll();

    // Close all socket connections connected to this instance.
    for (Socket obj in _clientsConnected) {
      obj.close();
    }
    _clientsConnected.clear();

    // Close all socket connections this instance has connected to.
    for (Socket obj in _connectedTo) {
      obj.close();
    }
    _connectedTo.clear();

    // Remove this instance.
    print('Server closed on: ${_serverSocket.address.address}');
    _instances.remove(_name);
    _serverSocket.close();
  }

  /// Sends a [Message] object to a remote instance listening on
  /// `address`. A message can contain a lot of data, see: [Message].
  Future<MessageOperationResult> send(String address, Message msg) async {
    Socket? socket = await _connectTo(address);

    if (socket == null) {
      print('Failed to send message to remote instance due to connection error! Target address: $address');
      return Future.value(MessageOperationResult.error(null));
    }

    msg._fromToAddr = MessageAddress(address);
    socket.write(msg.toString());
    print('Message sent from this instance to [remote instance] (TARGET address!): $address');
    return Future.value(MessageOperationResult.success());
  }

  /// Connect this instance to a remote instance using an `address`.
  ///
  /// The returned [Socket] is the socket that this instance
  /// connected to.
  /// The connection has failed if the [Socket] is `null`.
  Future<Socket?> _connectTo(String address) async {
    // Check for multiple connections from this instance to the same initial address.
    if (_connectedTo.any((s) => s.remoteAddress.address == address)) {
      //print(
      //    'Error occurred while connecting this instance to a remote instance (TARGET address!): $address. Initial address is already in use! Returning original Socket instead.');
      return Future.value(_connectedTo.firstWhere((s) => s.remoteAddress.address == address));
    }

    try {
      Socket socket = await Socket.connect(InternetAddress(address, type: InternetAddressType.unix), 0, timeout: Duration(seconds: 5));
      print('This instance connected to [remote instance] (TARGET address!): $address');
      _connectedTo.add(socket);
      socket.listen((_) {}, onDone: () async => _disconnectFrom(socket));
      return Future.value(socket);
    } catch (error) {
      print('Error occurred while connecting this instance to a remote instance: $error');
      return Future.value(null);
    }
  }

  /// Disconnect this instance from a remote instance.
  Future<void> _disconnectFrom(Socket socket) async {
    if (!_connectedTo.contains(socket)) return;

    print('This instance disconnected from [remote instance]: ${socket.remoteAddress.address}');
    _connectedTo.remove(socket);
    socket.close();
  }

  /// An [Event] that can be listened to. Listen for [Message]s
  /// sent from a remote instance to this instance, a message can
  /// contain a lot of data, see: [Message].
  /// For the use of the event system, see: [Event].
  final receiveAll = Event<MessageEventArgs>();

  /// Uses [Event].
  /// Listen for [Message]s sent from a remote instance to this instance
  /// using a specific port, a message can contain a lot of data, see: [Message].
  void receive(String address, void Function(MessageEventArgs?) handler) {
    receiveAll.subscribe((p0) {
      if (p0!.data._fromToAddr.getAddress() == address) handler(p0);
    });
  }
}

/// A message that can be first sent, then received somewhere else.
/// See [MessagingPipe.send] and [MessagingPipe.receive] for
/// using the messaging system to send/receive messages between
/// separate processes.
class Message {
  /// The name/ID of the message to be sent, should not contain spaces.
  /// This name should also be unique, to be sure, numbers can be used
  /// as a prefix/suffix if needed.
  String name;

  /// The address this message was sent from, or will be sent to.
  MessageAddress _fromToAddr = MessageAddress(null);

  /// The arguments of the message, can be left empty. Key & Value.
  /// These args are used to transport data alongside the message.
  Map<String, String> args;

  /// Converts any [String] to a new [Message] object.
  static Message fromString(String str) {
    Message result = Message(_getSubstringBeforeFirstSpace(str), {});

    var pairs = str.replaceFirst(result.name, "").trim().split(RegExp(r'(?<!\\);'));
    for (var pair in pairs) {
      var keyValue = pair.split(RegExp(r'(?<!\\):'));
      if (keyValue.length == 2) {
        var key = _doIllegalCharacters(keyValue[0].replaceAll(RegExp(r'(?<!\\)"'), ''), false).trim();
        var value = _doIllegalCharacters(keyValue[1].replaceAll(RegExp(r'(?<!\\)"'), ''), false).trim();
        result.args[key] = value;
      }
    }

    // Special keyvalue pair: address
    if (MessageAddress(result.args["__MSGDAT_ADDRESS__"]).getAddress() != null) {
      result._fromToAddr = MessageAddress(result.args["__MSGDAT_ADDRESS__"]);
    }

    result.name = validateName(result.name, false);
    return result;
  }

  /// Converts this [Message] object to a [String] type.
  @override
  String toString() {
    String result = "${validateName(name, true)} ";

    // Special keyvalue pair: address
    if (_fromToAddr.getAddress() != null) {
      args["__MSGDAT_ADDRESS__"] = _fromToAddr.getAddress()!;
    }

    args.forEach((key, value) {
      result += '"${_doIllegalCharacters(key, true)}":"${_doIllegalCharacters(value, true)}";';
    });

    return result;
  }

  /// Fixes invalid message names.
  ///
  /// If `toEscaped` is true, a `\` will be added before the illegal character,
  /// if false, it does the opposite.
  static String validateName(String str, bool toEscaped) {
    return toEscaped ? str.replaceAll(" ", r"\-") : str.replaceAll(r"\-", " ");
  }

  /// Get all text before the first " " letter in a [String].
  static String _getSubstringBeforeFirstSpace(String input) {
    List<String> parts = input.split(' ');
    if (parts.isNotEmpty) {
      return parts.first;
    }
    return '';
  }

  /// Add / Remove escape characters from a string with illegal characters.
  /// This has to be done because the message is sent as a string, and uses
  /// characters like ":" and ";" to separate parts of the message.
  ///
  /// If `toEscaped` is true, a `\` will be added before the illegal character,
  /// if false, it does the opposite.
  static String _doIllegalCharacters(String str, bool toEscaped) {
    String retStr = str;
    List<String> chars = ['"', ';', ':'];

    if (toEscaped) {
      for (var c in chars) {
        retStr = retStr.replaceAll(c, r"\" + c);
      }
    } else {
      for (var c in chars) {
        retStr = retStr.replaceAll(r"\" + c, c);
      }
    }

    return retStr;
  }

  /// Contruct a [Message] object containing a required name,
  /// the name should not have any blank spaces. `args` can
  /// be empty, not null.
  Message(this.name, this.args);
}

/// The address that gets sent within a [Message]. The address is the path
/// to the Unix Domain Socket file.
class MessageAddress {
  static const String errMsg = "Invoking 'toString()' on an instance of MessageAddress is not supported! Use 'getAddress()' instead.";
  final String? _address;

  /// Returns null if the address is invalid.
  String? getAddress() {
    if (_address == null || _address == "") return null;

    return _address!.trim().replaceAll(r"\", "/");
  }

  @Deprecated(errMsg)
  @override
  String toString() => throw Exception(errMsg);

  const MessageAddress(this._address);
}

/// [EventArgs] for receiving messages from a remote instance. Contains all
/// needed data.
class MessageEventArgs extends EventArgs {
  /// The socket the message was sent from.
  final Socket from;

  /// The [Message] that was sent from the remote instance.
  final Message data;

  MessageEventArgs(this.from, this.data);
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
