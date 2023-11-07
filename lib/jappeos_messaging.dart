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

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:event/event.dart';
import 'package:uuid/uuid.dart';

/// Use to represent **unknown** values in [String] objects that are either logged
/// to the console, or used in an exception.
const _kUnknownPlaceholder = "<unknown>";

/// Use to represent **invalid** values in [String] objects that are either logged
/// to the console, or used in an exception.
const _kInvalidPlaceholder = "<invalid>";

/// Use this class to send/receive messages between processes using the JappeOS
/// messaging system.
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

  /// The servers [StreamSubscription] that listens to data from clients.
  late StreamSubscription<Socket> _serverListenerSubscription;

  /// Holds a list of clients connected to this instance.
  ///
  /// [Socket] is the socket that has connected to this instance.
  ///
  /// [MessagingAddress] is the address of the socket which connected to this instance.
  final Map<Socket, MessagingAddress> _clientsConnected = {};

  /// Holds a list of clients this instance has connected to.
  ///
  /// [Socket] is the socket this intance is connected to.
  ///
  /// [MessagingAddress] is the address this instance is connected to.
  final Map<Socket, MessagingAddress> _connectedTo = {};

  /// The name of this pipe.
  late String _name;

  /// Get the name of this pipe.
  String get name => _name;

  /// Get the address of this pipe.
  String get address => _serverSocket.address.address;

  /// Get a list of addresses of remote instances connected to this instance.
  List<String?> get connectedFromAddresses => _clientsConnected.values.toList().map((address) => address.getAddress()).toList();

  /// Get a list of addresses that this instance is connected to.
  List<String?> get connectedToAddresses => _connectedTo.values.toList().map((address) => address.getAddress()).toList();

  /// Initializes the messaging system with a `name` to use.
  /// This makes it possible for the "server" (this process) to send and receive
  /// [Message]s using the other methods provided by this class.
  ///
  /// [MessagingPipe] will return null if an error has occurred.
  ///
  /// NOTE: Remember to call [clean] after using this [MessagingPipe] to clean up all resources.
  static Future<MessagingPipe?> init(String name, [bool useCustomDirectory = false]) async {
    name = MessagingAddress(name).getAddress(true) ?? "";
    if (!Platform.isLinux) {
      throw Exception("Unsupported platform! 'Platform.isLinux' returned false.");
    } else if (_instances.contains(name)) {
      throw Exception("A messaging pipe with the name '$name' is already initialised!");
    }

    MessagingPipe thisObj = MessagingPipe._(name);
    InternetAddress address;
    var runtimeDir = MessagingAddress(Platform.environment['XDG_RUNTIME_DIR']).getAddress(true);

    // Set address
    if (useCustomDirectory) {
      address = InternetAddress(name, type: InternetAddressType.unix);
    } else {
      if (runtimeDir == null) throw Exception("The environment variable 'XDG_RUNTIME_DIR' returned null.");
      address = InternetAddress('$runtimeDir/$name', type: InternetAddressType.unix);
    }

    // Bind server socket
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

    // Handle connection of a client that is connected to this instance.
    thisObj._serverListenerSubscription = thisObj._serverSocket.listen((clientSocket) async {
      // Client connection is handled here.
      MessagingAddress? clientAddress;
      StreamSubscription<Uint8List>? clientSubscription;

      // Wait for hello message
      try {
        clientAddress = await thisObj._handleClientHelloMessage(clientSocket);
      } catch (e) {
        clientSocket.close().then((p0) => thisObj._handleClientDisconnection(clientSocket));
        print('Failed to receive hello message from remote instance (${clientAddress!.getAddress(true) ?? _kInvalidPlaceholder}): $e');
        return;
      }

      // Succesful connection >>
      print('New remote client connected: ${clientAddress.getAddress()}');
      thisObj._clientsConnected[clientSocket] = clientAddress;

      // Start listening for messages from the client & invoke the 'receive' event.
      clientSubscription = clientSocket.listen((data) async {
        // When the client sends data.
        thisObj._handleClientData(clientSocket, data);
      }, onDone: () async {
        // When the client disconnects.
        clientSubscription?.cancel();
        thisObj._handleClientDisconnection(clientSocket);
      });
    });

    return Future.value(thisObj);
  }

  /// Handle the hello message sent from a client that just connected to this instance.
  Future<MessagingAddress> _handleClientHelloMessage(Socket clientSocket) async {
    final completer = Completer<MessagingAddress>();
    StreamSubscription<Uint8List> clientListener;

    clientListener = clientSocket.listen(
      (data) async {
        var request = String.fromCharCodes(data).trim();
        var received = Message.fromString(request);

        if (received.name == _SpecialMessages.kMSG_NAME_HelloMsg && received.args.containsKey(_SpecialMessageArgs.kMSG_ARG_MsgAddress)) {
          var address = MessagingAddress(received.args[_SpecialMessageArgs.kMSG_ARG_MsgAddress]);
          if (address.getAddress() == null) return;

          completer.complete(address);
        }
      },
    );

    Timer? timeoutTimer;
    timeoutTimer = Timer(Duration(seconds: 5), () {
      if (!completer.isCompleted) {
        // Timeout occurred
        completer.complete(MessagingAddress(null));
      }
      timeoutTimer!.cancel();
    });

    var finalResult = await completer.future; // Wait for either completion or timeout

    // Make sure to cancel the listener after the future completes
    clientListener.cancel();

    // Throw exception incase of a timeout
    if (finalResult.getAddress() == null) throw Exception("Handling hello message timed out!");

    return finalResult;
  }

  /// Handle data received from a client connected to this instance.
  void _handleClientData(Socket clientSocket, Uint8List data) async {
    var request = String.fromCharCodes(data).trim();
    print('Received request from remote instance (${_clientsConnected[clientSocket]!.getAddress(true) ?? _kUnknownPlaceholder}): $request');
    receiveAll.broadcast(MessageEventArgs(clientSocket, Message.fromString(request)));
  }

  /// Handle the disconnection of a client coonected to this instance,
  /// a client needs to connect first to send messages.
  void _handleClientDisconnection(Socket clientSocket) async {
    print('Client disconnected: ${_clientsConnected[clientSocket]?.getAddress(true) ?? _kUnknownPlaceholder}');
    _clientsConnected.remove(clientSocket);
  }

  /// Stops this "server" (this instance) and cleans everything up.
  /// After this method is called, [Message]s can no longer be sent or received
  /// from/to this instance.
  void clean() async {
    receiveAll.unsubscribeAll();

    // Close all socket connections connected to this instance.
    _clientsConnected.forEach((key, value) async {
      key.close();
    });
    _clientsConnected.clear();

    // Close all socket connections this instance has connected to.
    _connectedTo.forEach((key, value) {
      key.close();
    });
    _connectedTo.clear();

    // Remove this instance.
    print('Server closed on: ${_serverSocket.address.address}');
    _instances.remove(_name);
    _serverListenerSubscription.cancel();
    _serverSocket.close();
  }

  /// Sends a [Message] object to a remote instance listening on `address`.
  /// A message can contain a lot of data, see: [Message].
  /// 
  /// Keeping `callback` as null will make this message not receive a callback.
  /// 
  /// Setting `answerToUUID` will declare this message as a callback/answer to
  /// another message.
  Future<MessageOperationResult> send(String address, Message msg, {Message Function()? callback, List<int>? answerToUUID}) async {
    assert(callback == null || answerToUUID == null); // <-- TODO needed?  Other things have to be modified to disallow having a send-to and a answer UUID

    address = MessagingAddress(address).getAddress(true) ?? "";
    Socket? socket = await _connectTo(address);

    if (socket == null) {
      print('Failed to send message to remote instance due to connection error! Target address: $address');
      return Future.value(MessageOperationResult.error(null));
    }

    msg._fromToAddr = MessagingAddress(_serverSocket.address.address);
    socket.write(msg.toString());
    print('Message sent from this instance to [remote instance] (TARGET address!): $address');
    return Future.value(MessageOperationResult.success());
  }

  /// Connect this instance to a remote instance using an `address`.
  ///
  /// The returned [Socket] is the socket that this instance connected to.
  /// The connection has failed if the [Socket] is `null`.
  Future<Socket?> _connectTo(String address) async {
    address = MessagingAddress(address).getAddress(true) ?? "";

    // Check for multiple connections from this instance to the same initial address.
    if (_connectedTo.values.any((s) => s.getAddress() == address)) {
      //print(
      //    'Error occurred while connecting this instance to a remote instance (TARGET address!): $address. Initial address is already in use! Returning original Socket instead.');
      return Future.value(_connectedTo.keys.firstWhere((k) => _connectedTo[k] == _connectedTo.values.firstWhere((s) => s.getAddress() == address)));
    }

    // A function to send a hello message to the remote instance
    Future<void> sayHello(Socket socket) async {
      final message = _SpecialMessages.constructHelloMessage(MessagingAddress(_serverSocket.address.address));

      socket.write(message.toString());
    }

    try {
      Socket socket = await Socket.connect(InternetAddress(address, type: InternetAddressType.unix), 0, timeout: Duration(seconds: 5));
      print('This instance connected to [remote instance] (TARGET address!): $address');
      _connectedTo[socket] = MessagingAddress(address);

      await sayHello(socket);
      socket.listen((_) {}, onDone: () async => _disconnectFrom(socket));

      return Future.value(socket);
    } catch (error) {
      print('Error occurred while connecting this instance to a remote instance: $error');
      return Future.value(null);
    }
  }

  /// Disconnect this instance from a remote instance.
  Future<void> _disconnectFrom(Socket socket) async {
    if (!_connectedTo.containsKey(socket)) return;

    print('This instance disconnected from [remote instance]: ${socket.remoteAddress.address}');
    _connectedTo.remove(socket);
    socket.close();
  }

  /// An [Event] that can be listened to. Listen for [Message]s sent from a
  /// remote instance to this instance, a message can contain a lot of data,
  /// see: [Message].
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

/// A class that contains special messages with special IDs that need to be
/// sent in order for the messaging system to work.
class _SpecialMessages {
  /// The name of a hello message.
  /// ignore: constant_identifier_names
  static const kMSG_NAME_HelloMsg = "__HELLO__";

  /// Construct a hello message ([kMSG_NAME_HelloMsg]).
  /// The `address` is used to send the address with the message.
  static Message constructHelloMessage(MessagingAddress address) {
    return Message(kMSG_NAME_HelloMsg, {_SpecialMessageArgs.kMSG_ARG_MsgAddress: address.getAddress() ?? ""});
  }
}

/// A class that contains special arguments (key-value pairs) to be sent
/// within messages
class _SpecialMessageArgs {
  /// The ARGUMENT (key) name of an address in a message.
  /// The value of this address should contain the address the message came from.
  // ignore: constant_identifier_names
  static const kMSG_ARG_MsgAddress = "__MSGDAT_ADDRESS__";

  /// The ARGUMENT (key) name of a unique callback ID in a message.
  /// These can be used to identify messages from each other. Mainly used for
  /// messages that need an answer back from the remote instance.
  ///
  /// This is the send-to variant of the callback ID. This will be sent to a
  /// remote instance, afterwhich, we will wait for an answer with a matching
  /// '__MSGDAT_CBUUID_ANSWER__' ID.
  // ignore: constant_identifier_names
  static const kMSG_ARG_MsgCallbackUUIDsendto = "__MSGDAT_CBUUID_SENDTO__";

  /// The ARGUMENT (key) name of a unique callback ID in a message.
  /// These can be used to identify messages from each other. Mainly used for
  /// messages that need an answer back from the remote instance.
  ///
  /// This is the answer variant of the callback ID. This will be the same as a
  /// '__MSGDAT_CBUUID_SENDTO__' arg of a specific message.
  // ignore: constant_identifier_names
  static const kMSG_ARG_MsgCallbackUUIDanswer = "__MSGDAT_CBUUID_ANSWER__";
}

/// A message that can be first sent, then received somewhere else.
/// See [MessagingPipe.send] and [MessagingPipe.receive] for using the
/// messaging system to send/receive messages between separate processes.
class Message {
  /// The name/ID of the message to be sent, should not contain spaces.
  /// This name should also be unique, to be sure, numbers can be used as a
  /// prefix/suffix if needed.
  String name;

  /// The address this message was sent from, or will be sent to.
  MessagingAddress _fromToAddr = MessagingAddress(null);

  /// Callback ID to send and wait for an answer [Message] that has this ID as
  /// its 'answerCallbackUUID'.
  List<int>? _sendToCallbackUUID;

  /// Answer ID to a [Message] with this 'sendToCallbackUUID'.
  List<int>? _answerCallbackUUID;

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
    if (MessagingAddress(result.args[_SpecialMessageArgs.kMSG_ARG_MsgAddress]).getAddress() != null) {
      result._fromToAddr = MessagingAddress(result.args[_SpecialMessageArgs.kMSG_ARG_MsgAddress]);
    }

    // Special keyvalue pair: send-to callback ID TODO
    if (result.args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUIDsendto] != null) {
      result._sendToCallbackUUID = Uuid.parse(result.args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUIDsendto]!);
    }

    // Special keyvalue pair: answer callback ID TODO
    if (result.args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUIDanswer] != null) {
      result._answerCallbackUUID = Uuid.parse(result.args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUIDanswer]!);
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
      args[_SpecialMessageArgs.kMSG_ARG_MsgAddress] = _fromToAddr.getAddress()!;
    }

    // Special keyvalue pair: send-to callback ID TODO
    if (_sendToCallbackUUID != null) {
      args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUIDsendto] = Uuid.unparse(_sendToCallbackUUID!);
    }

    // Special keyvalue pair: answer callback ID TODO
    if (_answerCallbackUUID != null) {
      args[_SpecialMessageArgs.kMSG_ARG_MsgCallbackUUIDanswer] = Uuid.unparse(_answerCallbackUUID!);
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

  /// Get all text before the first " " (whitespace) letter in a [String].
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

  /// Contruct a [Message] object containing a required name, the name should
  /// not have any blank spaces. `args` can be empty, not null.
  Message(this.name, this.args, {List<int>? sendToCallbackUUID, List<int>? answerCallbackUUID})
      : _sendToCallbackUUID = sendToCallbackUUID,
        _answerCallbackUUID = answerCallbackUUID;
}

/// The address that gets sent within a [Message]. The address is the path to
/// the source Unix Domain Socket file.
class MessagingAddress implements Comparable<String> {
  /// Error message to throw when trying to invoke `toString()`.
  static const String _kErrMsg = "Invoking 'toString()' on an instance of MessageAddress is not supported! Use 'getAddress()' instead.";

  /// The address of this object. Cannot be modified externally after this
  /// object has been instantiated. The address should be the path to the
  /// Unix Domain Socket file.
  final String? _address;

  /// Returns null if the address is invalid.
  ///
  /// RULE: Note! Always only compare with a [String] that has invoked the
  /// `toMessageAddressString()` mathod from the [_MessageAddressExt] extension.
  ///
  /// If `useInvalidAddressStringPlaceholder` is true, this method will never
  /// return null, instead, it will return "<invalid>". If this function returns
  /// "<invalid>", it is always an invalid address (in that case).
  String? getAddress([bool useInvalidAddressStringPlaceholder = false]) {
    if (_address == null || _address == "" || _address == _kInvalidPlaceholder) {
      if (useInvalidAddressStringPlaceholder) {
        return _kInvalidPlaceholder;
      } else {
        return null;
      }
    }

    return _address!.trim().replaceAll(r"\", "/");
  }

  @override
  int compareTo(String other) {
    if (getAddress() == null) return -1;

    return getAddress()!.compareTo(MessagingAddress(other).getAddress() ?? "");
  }

  @Deprecated(_kErrMsg)
  @override
  String toString() => throw Exception(_kErrMsg);

  /// Instantiate a messaging address object with a path to a Unix Domain
  /// Socket file.
  const MessagingAddress(this._address);
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
