class GroupMessageModel {
  final String messageId;
  final String senderId;
  final String senderName;
  final String text;
  final int timestamp;
  final bool isQuickCard;
  final String cardType; // 'FUEL', 'WAIT_2MIN', 'REGROUP', 'MECHANICAL', 'CUSTOM'

  GroupMessageModel({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.timestamp,
    this.isQuickCard = false,
    this.cardType = 'CUSTOM',
  });

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'senderId': senderId,
        'senderName': senderName,
        'text': text,
        'timestamp': timestamp,
        'isQuickCard': isQuickCard,
        'cardType': cardType,
      };

  factory GroupMessageModel.fromJson(Map<String, dynamic> json) =>
      GroupMessageModel(
        messageId: json['messageId'] ?? '',
        senderId: json['senderId'] ?? '',
        senderName: json['senderName'] ?? '',
        text: json['text'] ?? '',
        timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
        isQuickCard: json['isQuickCard'] ?? false,
        cardType: json['cardType'] ?? 'CUSTOM',
      );
}
