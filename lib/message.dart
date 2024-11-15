//  JappeOS-Messaging, A pipe messaging system for JappeOS/Linux.
//  Copyright (C) 2024  Jappe02
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

import 'dart:typed_data';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;

class Message {
  /// Serializes a [Message] into a `Uint8List` using MessagePack.
  ///
  /// Converts the [Message] object into a `Map`, then encodes that map
  /// into binary data using MessagePack.
  static Uint8List serialize(Message msg) {
    // Convert Message object to a Map.
    final Map<String, dynamic> messageMap = {
      'id': msg.id,
      'data': msg.data, // Preserve the complex structure of 'data'
    };

    // Serialize the Map into binary data using MessagePack.
    return Uint8List.fromList(msgpack.serialize(messageMap));
  }

  /// Deserializes a `Uint8List` back into a [Message] object using MessagePack.
  ///
  /// Takes the binary data, decodes it into a `Map` using MessagePack, and
  /// constructs a [Message] object from that map.
  static Message deserialize(Uint8List data) {
    // Decode binary data into a Map using MessagePack.
    final Map<String, dynamic> messageMap = msgpack.deserialize(data);

    // Extract 'id' and 'data' from the Map and create a Message object.
    return Message(
      messageMap['id'],
      data: Map<String, dynamic>.from(messageMap['data']), // Ensure correct type
    );
  }

  const Message(this.id, {this.data = const {}});

  final int id;
  final Map<String, dynamic> data; // Allow complex nested data structures

  @override
  String toString() {
    return 'Message{id: $id, data: $data}';
  }
}