import 'package:cloud_firestore/cloud_firestore.dart';

class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ============= USER MANAGEMENT =============

  Future<void> createUserProfile({
    required String userId,
    required String email,
    required String name,
  }) async {
    try {
      await _firestore.collection('users').doc(userId).set({
        'email': email,
        'name': name,
        'storeName': 'My Food Store',
        'storeType': 'Retailer',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'stats': {
          'totalItems': 0,
          'freshItems': 0,
          'expiringSoonItems': 0,
          'expiredItems': 0,
          'inventoryValue': 0,
          'dailyScans': 0,
        },
        'settings': {
          'expiryAlertDays': 3,
          'lowStockThreshold': 5,
          'notifications': true,
        },
      }, SetOptions(merge: true));
    } catch (e) {
      throw Exception('Error creating user profile: $e');
    }
  }

  Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    try {
      final doc = await _firestore.collection('users').doc(userId).get();
      return doc.data();
    } catch (e) {
      throw Exception('Error fetching user profile: $e');
    }
  }

  Stream<DocumentSnapshot> getUserStream(String userId) {
    return _firestore.collection('users').doc(userId).snapshots();
  }

  // ============= FOOD ITEMS MANAGEMENT =============

  Future<String> addFoodItem({
    required String userId,
    required String name,
    required String category,
    required double quantity,
    required String unit,
    required DateTime expiryDate,
    String? barcode,
    String? notes,
    bool scanned = false,
  }) async {
    try {
      // Calculate status based on expiry date
      final now = DateTime.now();
      final daysUntilExpiry = expiryDate.difference(now).inDays;
      String status;
      
      if (daysUntilExpiry < 0) {
        status = 'Expired';
      } else if (daysUntilExpiry == 0) {
        status = 'Expiring Today';
      } else if (daysUntilExpiry <= 3) {
        status = 'Expiring Soon';
      } else {
        status = 'Fresh';
      }

      final itemData = {
        'name': name,
        'category': category,
        'quantity': quantity,
        'unit': unit,
        'expiryDate': Timestamp.fromDate(expiryDate),
        'expiryTimestamp': Timestamp.fromDate(expiryDate),
        'status': status,
        'barcode': barcode,
        'notes': notes ?? '',
        'scanned': scanned,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'value': (quantity * 5).toDouble(), // Estimated value $5 per unit
      };

      final docRef = await _firestore
          .collection('users')
          .doc(userId)
          .collection('food_items')
          .add(itemData);

      // Update user stats
      await _updateUserStats(userId);

      return docRef.id;
    } catch (e) {
      throw Exception('Error adding food item: $e');
    }
  }

  Future<void> deleteFoodItem({
    required String userId,
    required String itemId,
  }) async {
    try {
      await _firestore
          .collection('users')
          .doc(userId)
          .collection('food_items')
          .doc(itemId)
          .delete();

      // Update user stats
      await _updateUserStats(userId);
    } catch (e) {
      throw Exception('Error deleting food item: $e');
    }
  }

  Stream<QuerySnapshot> getFoodItemsStream(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('food_items')
        .orderBy('expiryTimestamp')
        .snapshots();
  }

  Stream<QuerySnapshot> getFilteredFoodItemsStream(
    String userId, 
    String filter
  ) {
    Query query = _firestore
        .collection('users')
        .doc(userId)
        .collection('food_items')
        .orderBy('expiryTimestamp');

    if (filter == 'Fresh') {
      query = query.where('status', isEqualTo: 'Fresh');
    } else if (filter == 'Expiring Soon') {
      query = query.where('status', whereIn: ['Expiring Soon', 'Expiring Today']);
    } else if (filter == 'Expired') {
      query = query.where('status', isEqualTo: 'Expired');
    }

    return query.snapshots();
  }

  Stream<QuerySnapshot> getRecentActivityStream(String userId, {int limit = 5}) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('food_items')
        .orderBy('updatedAt', descending: true)
        .limit(limit)
        .snapshots();
  }

  // ============= STATS & ANALYTICS =============

  Future<Map<String, dynamic>> getUserStats(String userId) async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('food_items')
          .get();

      int total = 0;
      int fresh = 0;
      int expiringSoon = 0;
      int expired = 0;
      double totalValue = 0;
      int lowStock = 0;
      
      final today = DateTime.now();
      final startOfDay = DateTime(today.year, today.month, today.day);
      int todayAdded = 0;

      for (final doc in snapshot.docs) {
        total++;
        final data = doc.data();
        
        final status = data['status'] as String? ?? 'Fresh';
        final quantity = (data['quantity'] as num?)?.toDouble() ?? 0;
        final value = (data['value'] as num?)?.toDouble() ?? 0;
        final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
        
        if (status == 'Fresh') {
          fresh++;
        } else if (status == 'Expiring Soon' || status == 'Expiring Today') {
          expiringSoon++;
        } else if (status == 'Expired') {
          expired++;
        }
        
        totalValue += value;
        
        if (quantity < 5) {
          lowStock++;
        }
        
        if (createdAt != null && createdAt.isAfter(startOfDay)) {
          todayAdded++;
        }
      }

      return {
        'totalItems': total,
        'freshItems': fresh,
        'expiringSoonItems': expiringSoon,
        'expiredItems': expired,
        'inventoryValue': totalValue,
        'lowStockItems': lowStock,
        'todayAdded': todayAdded,
      };
    } catch (e) {
      print('Error calculating stats: $e');
      return {
        'totalItems': 0,
        'freshItems': 0,
        'expiringSoonItems': 0,
        'expiredItems': 0,
        'inventoryValue': 0,
        'lowStockItems': 0,
        'todayAdded': 0,
      };
    }
  }

  Future<void> _updateUserStats(String userId) async {
    try {
      final stats = await getUserStats(userId);
      
      await _firestore.collection('users').doc(userId).update({
        'stats': {
          'totalItems': stats['totalItems'],
          'freshItems': stats['freshItems'],
          'expiringSoonItems': stats['expiringSoonItems'],
          'expiredItems': stats['expiredItems'],
          'inventoryValue': stats['inventoryValue'],
          'lowStockItems': stats['lowStockItems'],
        },
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      print('Error updating user stats: $e');
    }
  }

  // ============= CATEGORY DATA =============

  Future<Map<String, int>> getCategoryCounts(String userId) async {
    try {
      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('food_items')
          .get();

      final Map<String, int> categoryCounts = {};
      final defaultCategories = [
        'Fruits', 'Vegetables', 'Dairy', 'Meat', 'Bakery', 'Beverages',
        'Snacks', 'Grains', 'Spices', 'Other'
      ];

      // Initialize all categories with 0
      for (final category in defaultCategories) {
        categoryCounts[category] = 0;
      }

      // Count actual items
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final category = data['category'] as String? ?? 'Other';
        categoryCounts[category] = (categoryCounts[category] ?? 0) + 1;
      }

      return categoryCounts;
    } catch (e) {
      print('Error getting category counts: $e');
      return {
        'Fruits': 0,
        'Vegetables': 0,
        'Dairy': 0,
        'Meat': 0,
        'Bakery': 0,
        'Beverages': 0,
        'Snacks': 0,
        'Grains': 0,
        'Spices': 0,
        'Other': 0,
      };
    }
  }

  // ============= EXPIRY ALERTS =============

  Future<List<Map<String, dynamic>>> getExpiringItems(String userId, int days) async {
    try {
      final now = Timestamp.now();
      final futureDate = Timestamp.fromDate(
        DateTime.now().add(Duration(days: days)),
      );

      final snapshot = await _firestore
          .collection('users')
          .doc(userId)
          .collection('food_items')
          .where('expiryTimestamp', isGreaterThanOrEqualTo: now)
          .where('expiryTimestamp', isLessThanOrEqualTo: futureDate)
          .orderBy('expiryTimestamp')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data();
        final expiryDate = (data['expiryDate'] as Timestamp).toDate();
        final now = DateTime.now();
        final daysUntilExpiry = expiryDate.difference(now).inDays;
        
        return {
          'id': doc.id,
          'name': data['name'] as String? ?? 'Item',
          'category': data['category'] as String? ?? 'Other',
          'quantity': (data['quantity'] as num?)?.toDouble() ?? 0,
          'unit': data['unit'] as String? ?? 'pieces',
          'expiryDate': expiryDate,
          'daysUntilExpiry': daysUntilExpiry,
          'status': data['status'] as String? ?? 'Fresh',
        };
      }).toList();
    } catch (e) {
      print('Error fetching expiring items: $e');
      return [];
    }
  }

  // ============= BARCODE/SCANNING =============

  Future<Map<String, dynamic>?> getProductByBarcode(String barcode) async {
    try {
      final snapshot = await _firestore
          .collection('barcode_products')
          .where('barcode', isEqualTo: barcode)
          .limit(1)
          .get();

      if (snapshot.docs.isNotEmpty) {
        return snapshot.docs.first.data();
      }

      return null;
    } catch (e) {
      print('Error fetching product by barcode: $e');
      return null;
    }
  }
}