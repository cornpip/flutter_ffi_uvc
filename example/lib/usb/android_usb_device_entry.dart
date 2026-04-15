class AndroidUsbDeviceEntry {
  const AndroidUsbDeviceEntry({
    required this.deviceId,
    required this.deviceName,
    required this.vendorId,
    required this.productId,
    required this.productName,
    required this.manufacturerName,
    required this.serialNumber,
    required this.hasPermission,
  });

  factory AndroidUsbDeviceEntry.fromMap(Map<Object?, Object?> map) {
    return AndroidUsbDeviceEntry(
      deviceId: map['deviceId'] as int? ?? -1,
      deviceName: map['deviceName'] as String? ?? '',
      vendorId: map['vendorId'] as int? ?? 0,
      productId: map['productId'] as int? ?? 0,
      productName: map['productName'] as String? ?? '',
      manufacturerName: map['manufacturerName'] as String? ?? '',
      serialNumber: map['serialNumber'] as String? ?? '',
      hasPermission: map['hasPermission'] as bool? ?? false,
    );
  }

  final int deviceId;
  final String deviceName;
  final int vendorId;
  final int productId;
  final String productName;
  final String manufacturerName;
  final String serialNumber;
  final bool hasPermission;

  String get title {
    final String label = productName.isNotEmpty ? productName : deviceName;
    return '$label (${vendorId.toRadixString(16)}:${productId.toRadixString(16)})';
  }

  String get subtitle {
    final List<String> parts = <String>[
      if (manufacturerName.isNotEmpty) manufacturerName,
      if (serialNumber.isNotEmpty) 'S/N $serialNumber',
      hasPermission ? 'permission granted' : 'permission required',
    ];
    return parts.join(' • ');
  }
}
