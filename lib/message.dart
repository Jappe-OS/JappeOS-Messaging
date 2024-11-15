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

import 'dart:convert';
import 'dart:typed_data';

class Message {
  /// Serializes a [Message] into a `Uint8List` (JSON encoded).
  ///
  /// Converts the [Message] object into a JSON string, then encodes that string
  /// into a list of bytes using UTF-8 encoding.
  static Uint8List serialize(Message msg) {
    // Convert Message object to a Map.
    final Map<String, dynamic> jsonMap = {
      'id': msg.id,
      'data': msg.data, // Allow more complex data structures
    };
    
    // Convert the Map to a JSON string.
    final jsonString = jsonEncode(jsonMap);
    
    // Convert JSON string to a list of bytes (UTF-8 encoding).
    return Uint8List.fromList(utf8.encode(jsonString));
  }

  /// Deserializes a `Uint8List` back into a [Message] object.
  ///
  /// Takes the byte data, decodes it into a JSON string, and then parses that string
  /// into a [Map] which is used to construct a [Message] object.
  static Message deserialize(Uint8List data) {
    // Convert Uint8List to a UTF-8 string.
    final jsonString = utf8.decode(data);
    
    // Parse the JSON string into a Map.
    final Map<String, dynamic> jsonMap = jsonDecode(jsonString);

    // Extract 'id' and 'data' from the Map and create a Message object.
    return Message(
      jsonMap['id'],
      data: Map<String, dynamic>.from(jsonMap['data']), // Allow complex objects
    );
  }

  const Message(this.id, {this.data = const {}});

  final int id;
  final Map<String, dynamic> data; // Allow dynamic data types

  @override
  String toString() {
    return 'Message{id: $id, data: $data}';
  }
}