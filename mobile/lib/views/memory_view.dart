import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/entity.dart';
import '../services/database_service.dart';

class MemoryView extends StatefulWidget {
  const MemoryView({super.key});

  @override
  State<MemoryView> createState() => _MemoryViewState();
}

class _MemoryViewState extends State<MemoryView> {
  final _db = DatabaseService.instance;
  final _searchController = TextEditingController();

  List<Entity> _entities = [];
  String _selectedCategory = 'All';
  bool _isLoading = false;
  bool _isDeduping = false;

  final List<String> _categories = [
    'All',
    'DOCUMENT',
    'CHAT',
    'GMAIL',
    'MEMORY',
  ];

  @override
  void initState() {
    super.initState();
    _loadEntities(cleanDuplicates: true);
  }

  Future<void> _loadEntities({
    String? query,
    bool cleanDuplicates = false,
  }) async {
    setState(() {
      _isLoading = true;
      if (cleanDuplicates) _isDeduping = true;
    });
    try {
      if (cleanDuplicates) {
        await _db.deduplicateEntities();
      }
      final results = await _db.getAllEntities(
        typeFilter: _selectedCategory,
        searchQuery: query,
      );
      if (!mounted) return;
      setState(() {
        _entities = results;
        _isLoading = false;
        if (cleanDuplicates) _isDeduping = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        if (cleanDuplicates) _isDeduping = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cabinet refresh failed: $error')));
    }
  }

  Future<void> _deleteEntity(String id) async {
    await _db.deleteEntity(id);
    await _loadEntities();
  }

  Future<void> _cleanDuplicates() async {
    if (_isDeduping) return;
    setState(() => _isDeduping = true);
    try {
      final result = await _db.deduplicateEntities();
      await _loadEntities(query: _searchController.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.removed == 0
                ? 'No duplicate Cabinet files found.'
                : 'Removed ${result.removed} duplicate Cabinet nodes.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Duplicate cleanup failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _isDeduping = false);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showNodeInspector(Entity entity) async {
    final edges = await _db.getEdgesForEntity(entity.id);
    if (!mounted) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.85,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1E1E2C).withValues(alpha: 0.95)
                : Colors.white.withValues(alpha: 0.95),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
            border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    color: Colors.grey.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Knowledge Node',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      entity.sourceConnector?.toUpperCase() ??
                          entity.entityType.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'ID: ${entity.id}',
                style: const TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'RAW CONTENT',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.3)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.1),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      entity.content ?? 'No content',
                      style: TextStyle(
                        color: isDark ? Colors.white70 : Colors.black87,
                        fontSize: 15,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'RELATIONSHIPS (EDGES)',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 8),
              if (edges.isEmpty)
                const Text(
                  'No connections to other nodes.',
                  style: TextStyle(
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                )
              else
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    itemCount: edges.length,
                    itemBuilder: (context, index) {
                      final edge = edges[index];
                      final isSource = edge.sourceId == entity.id;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.purpleAccent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.purpleAccent.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isSource ? Icons.arrow_forward : Icons.arrow_back,
                              color: Colors.purpleAccent,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${edge.relationshipType} -> ${isSource ? edge.targetId : edge.sourceId}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.purpleAccent,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteEntity(entity.id);
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete Node'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
                    foregroundColor: Colors.redAccent,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Knowledge Graph Explorer',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Clean duplicates',
            icon: _isDeduping
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cleaning_services_outlined),
            onPressed: _isDeduping ? null : _cleanDuplicates,
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.sync),
            onPressed: () => _loadEntities(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search local graph...',
                prefixIcon: const Icon(Icons.search, color: Colors.blueAccent),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _loadEntities();
                  },
                ),
                filled: true,
                fillColor: isDark
                    ? const Color(0xFF252538)
                    : Colors.grey.shade100,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onSubmitted: (val) => _loadEntities(query: val),
            ),
          ),
          SizedBox(
            height: 50,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final cat = _categories[index];
                final isSelected = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: FilterChip(
                    label: Text(cat),
                    selected: isSelected,
                    onSelected: (selected) {
                      setState(() => _selectedCategory = cat);
                      _loadEntities(query: _searchController.text);
                    },
                    selectedColor: Colors.blueAccent.withValues(alpha: 0.2),
                    checkmarkColor: Colors.blueAccent,
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.blueAccent : Colors.grey,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                    backgroundColor: isDark
                        ? const Color(0xFF1E1E2C)
                        : Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: isSelected
                            ? Colors.blueAccent
                            : Colors.grey.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _entities.isEmpty
                ? const Center(
                    child: Text(
                      'No knowledge nodes found.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    itemCount: _entities.length,
                    itemBuilder: (context, index) {
                      final entity = _entities[index];

                      IconData icon = Icons.data_object;
                      Color iconColor = Colors.grey;
                      final type =
                          entity.sourceConnector?.toUpperCase() ??
                          entity.entityType.toUpperCase();

                      if (type == 'DOCUMENT' ||
                          type == 'LOCAL_PDF' ||
                          type == 'PDF') {
                        icon = Icons.picture_as_pdf;
                        iconColor = Colors.redAccent;
                      } else if (type == 'CHAT' || type == 'WHATSAPP') {
                        icon = Icons.chat;
                        iconColor = Colors.greenAccent;
                      } else if (type == 'GMAIL') {
                        icon = Icons.email;
                        iconColor = Colors.orangeAccent;
                      } else if (type == 'MEMORY' ||
                          type == 'PREFERENCE' ||
                          type == 'CHAT_AGENT') {
                        icon = Icons.psychology;
                        iconColor = Colors.purpleAccent;
                      }

                      return Dismissible(
                        key: Key(entity.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (direction) {
                          _deleteEntity(entity.id);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Node deleted from graph.'),
                            ),
                          );
                        },
                        child: Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          elevation: 0,
                          color: isDark
                              ? const Color(0xFF1E1E2C)
                              : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.1),
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _showNodeInspector(entity),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: iconColor.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(icon, color: iconColor),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          entity.content ?? 'Empty Node',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 14,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Row(
                                          children: [
                                            Text(
                                              type,
                                              style: TextStyle(
                                                color: iconColor,
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              DateFormat.yMMMd().format(
                                                DateTime.fromMillisecondsSinceEpoch(
                                                  entity.createdAt,
                                                ),
                                              ),
                                              style: const TextStyle(
                                                color: Colors.grey,
                                                fontSize: 10,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
