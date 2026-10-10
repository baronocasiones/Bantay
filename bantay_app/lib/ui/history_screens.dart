import 'package:bantay_app/alerts/incident_history.dart';
import 'package:flutter/material.dart';

const _historyBlue = Color(0xFF013791);
const _historyGreen = Color(0xFF185C43);
const _historyRed = Color(0xFFC52222);

enum IncidentHistoryFilter { all, sent, cancelled }

class IncidentHistoryScreen extends StatelessWidget {
  const IncidentHistoryScreen({
    super.key,
    required this.records,
    required this.searchController,
    required this.filter,
    required this.onSearchChanged,
    required this.onFilterChanged,
    required this.onOpenIncident,
  });

  final List<IncidentHistoryRecord> records;
  final TextEditingController searchController;
  final IncidentHistoryFilter filter;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<IncidentHistoryFilter> onFilterChanged;
  final ValueChanged<IncidentHistoryRecord> onOpenIncident;

  List<IncidentHistoryRecord> get _visibleRecords {
    final query = searchController.text.trim().toLowerCase();
    return records.where((record) {
      final matchesFilter = switch (filter) {
        IncidentHistoryFilter.all => true,
        IncidentHistoryFilter.sent => record.isSent,
        IncidentHistoryFilter.cancelled => record.isCancelled,
      };
      if (!matchesFilter) return false;
      if (query.isEmpty) return true;
      final occurredAt = record.occurredAt?.toLocal();
      final date = occurredAt == null
          ? ''
          : '${occurredAt.toString()} ${_dateTime(occurredAt)}';
      return <String>[
        record.incidentId,
        _incidentType(record),
        record.contactName ?? '',
        date,
      ].any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleRecords;
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 100),
      children: [
        const Text(
          'Incident History',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        const Text(
          'Review saved emergency incidents',
          style: TextStyle(color: Color(0xFF697386)),
        ),
        const SizedBox(height: 22),
        TextField(
          controller: searchController,
          onChanged: onSearchChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search incidents',
            prefixIcon: const Icon(Icons.search),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(vertical: 15),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFE4E9F0)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFE4E9F0)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: _historyBlue, width: 1.5),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 9,
          children: [
            _FilterChip(
              label: 'All',
              selected: filter == IncidentHistoryFilter.all,
              onTap: () => onFilterChanged(IncidentHistoryFilter.all),
            ),
            _FilterChip(
              label: 'Sent',
              selected: filter == IncidentHistoryFilter.sent,
              onTap: () => onFilterChanged(IncidentHistoryFilter.sent),
            ),
            _FilterChip(
              label: 'Cancelled',
              selected: filter == IncidentHistoryFilter.cancelled,
              onTap: () => onFilterChanged(IncidentHistoryFilter.cancelled),
            ),
          ],
        ),
        const SizedBox(height: 25),
        const Text(
          'Recent Incidents',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          _HistoryEmptyState(
            hasRecords: records.isNotEmpty,
            filter: filter,
            query: searchController.text,
          )
        else
          for (final record in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _IncidentCard(
                record: record,
                onTap: () => onOpenIncident(record),
              ),
            ),
      ],
    );
  }
}

class IncidentDetailsScreen extends StatelessWidget {
  const IncidentDetailsScreen({
    super.key,
    required this.record,
    required this.onBack,
  });

  final IncidentHistoryRecord record;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final occurredAt = record.occurredAt?.toLocal();
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
      children: [
        Text(
          _incidentType(record),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        Text(
          occurredAt == null ? 'Date unavailable' : _dateTime(occurredAt),
          style: const TextStyle(color: Color(0xFF697386)),
        ),
        const SizedBox(height: 19),
        _DetailSection(
          title: 'Detection Information',
          icon: Icons.sensors_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!record.isManual) ...[
                _FactRow(
                  label: 'Impact strength',
                  value: record.peakG == null
                      ? 'Unavailable'
                      : '${record.peakG!.toStringAsFixed(1)} g',
                ),
                _FactRow(
                  label: 'Limited movement',
                  value: record.stillnessSeconds == null
                      ? 'Unavailable'
                      : '${record.stillnessSeconds} seconds',
                ),
                _FactRow(
                  label: 'Movement before event',
                  value: record.beforeImpact ?? 'Unavailable',
                ),
              ],
              _FactRow(label: 'Detection type', value: _incidentType(record)),
              _FactRow(label: 'Incident ID', value: record.incidentId),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _DetailSection(
          title: 'Timeline',
          icon: Icons.schedule_rounded,
          child: record.timeline.isEmpty
              ? const Text(
                  'Timeline unavailable',
                  style: TextStyle(color: Color(0xFF697386)),
                )
              : Column(
                  children: [
                    for (var i = 0; i < record.timeline.length; i++)
                      _TimelineRow(
                        event: record.timeline[i],
                        isLast: i == record.timeline.length - 1,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 14),
        _DetailSection(
          title: 'Emergency Response',
          icon: Icons.emergency_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FactRow(
                label: 'Emergency contact',
                value: record.contactName ?? 'Unavailable',
              ),
              _FactRow(
                label: 'Phone number',
                value: record.number ?? 'Unavailable',
              ),
              _FactRow(label: 'SMS status', value: _statusLabel(record.stage)),
              if (record.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    record.error!,
                    style: const TextStyle(color: _historyRed, fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
        if (!record.isCancelled && record.smsText != null) ...[
          const SizedBox(height: 14),
          _DetailSection(
            title: 'Exact SMS text',
            icon: Icons.sms_outlined,
            child: SelectableText(record.smsText!),
          ),
        ],
        const SizedBox(height: 14),
        _DetailSection(
          title: 'Technical Details',
          icon: Icons.info_outline_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FactRow(
                label: 'Source',
                value: record.isManual ? 'Manual SOS' : 'Fall detection',
              ),
              if (!record.isManual)
                _FactRow(
                  label: 'Impact strength',
                  value: record.peakG == null
                      ? 'Unavailable'
                      : '${record.peakG!.toStringAsFixed(1)} g',
                ),
              _FactRow(
                label: 'Current outcome',
                value: _statusLabel(record.stage),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Back to Incident History'),
          style: FilledButton.styleFrom(
            backgroundColor: _historyBlue,
            minimumSize: const Size.fromHeight(52),
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onTap(),
    selectedColor: const Color(0xFFDCEAFF),
    backgroundColor: Colors.white,
    side: BorderSide(color: selected ? _historyBlue : const Color(0xFFE2E7EF)),
    labelStyle: TextStyle(
      color: selected ? _historyBlue : const Color(0xFF344054),
      fontWeight: FontWeight.w600,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
  );
}

class _IncidentCard extends StatelessWidget {
  const _IncidentCard({required this.record, required this.onTap});
  final IncidentHistoryRecord record;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final date = record.occurredAt?.toLocal();
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(17),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFE5E9EF)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _incidentType(record),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  _StatusPill(stage: record.stage),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                date == null ? 'Date unavailable' : _dateTime(date),
                style: const TextStyle(color: Color(0xFF697386), fontSize: 13),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 15,
                runSpacing: 6,
                children: [
                  if (record.peakG != null)
                    _CardFact(
                      icon: Icons.bolt_rounded,
                      text: '${record.peakG!.toStringAsFixed(1)} g impact',
                    ),
                  if (record.contactName != null)
                    _CardFact(
                      icon: Icons.person_outline,
                      text: record.contactName!,
                    ),
                  if (record.peakG == null && record.contactName == null)
                    Text(
                      record.incidentId,
                      style: const TextStyle(
                        color: Color(0xFF697386),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardFact extends StatelessWidget {
  const _CardFact({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 15, color: _historyBlue),
      const SizedBox(width: 5),
      Text(
        text,
        style: const TextStyle(fontSize: 12, color: Color(0xFF475467)),
      ),
    ],
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.stage});
  final String stage;

  @override
  Widget build(BuildContext context) {
    final cancelled = stage == 'canceled' || stage == 'cancelled';
    final sent = stage == 'sent' || stage == 'delivered';
    final color = cancelled
        ? const Color(0xFF667085)
        : sent
        ? _historyGreen
        : _historyRed;
    final background = cancelled
        ? const Color(0xFFF0F1F3)
        : sent
        ? const Color(0xFFE2F4E8)
        : const Color(0xFFFFE7E5);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        _statusLabel(stage),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _HistoryEmptyState extends StatelessWidget {
  const _HistoryEmptyState({
    required this.hasRecords,
    required this.filter,
    required this.query,
  });
  final bool hasRecords;
  final IncidentHistoryFilter filter;
  final String query;

  @override
  Widget build(BuildContext context) {
    final noIncidents =
        !hasRecords &&
        query.trim().isEmpty &&
        filter == IncidentHistoryFilter.all;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 30),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE5E9EF)),
      ),
      child: Column(
        children: [
          Icon(
            noIncidents ? Icons.shield_outlined : Icons.search_off,
            size: 36,
            color: _historyBlue,
          ),
          const SizedBox(height: 11),
          Text(
            noIncidents ? 'No incidents yet' : 'No matching incidents',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 5),
          Text(
            noIncidents
                ? 'Saved fall alerts and manual SOS events will appear here.'
                : 'Try another search or filter.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF697386)),
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(17),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFFE5E9EF)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 19, color: _historyBlue),
            const SizedBox(width: 9),
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 13),
        child,
      ],
    ),
  );
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 145,
          child: Text(label, style: const TextStyle(color: Color(0xFF697386))),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event, required this.isLast});
  final IncidentTimelineEvent event;
  final bool isLast;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 22,
        child: Column(
          children: [
            Container(
              width: 9,
              height: 9,
              decoration: const BoxDecoration(
                color: _historyBlue,
                shape: BoxShape.circle,
              ),
            ),
            if (!isLast)
              Container(width: 1, height: 42, color: const Color(0xFFD9E0EA)),
          ],
        ),
      ),
      const SizedBox(width: 7),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                _dateTime(event.at.toLocal()),
                style: const TextStyle(fontSize: 12, color: Color(0xFF697386)),
              ),
              if (event.detail != null)
                Text(
                  event.detail!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF697386),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}

String _incidentType(IncidentHistoryRecord record) =>
    record.isManual ? 'Manual SOS' : 'Fall incident';

String _statusLabel(String stage) => switch (stage) {
  'sent' => 'Sent',
  'delivered' => 'Delivered',
  'canceled' || 'cancelled' => 'Cancelled',
  'queued' => 'Queued',
  'sending' => 'Sending',
  'failed' => 'Failed',
  'unknown' => 'Unknown',
  'counting' => 'Countdown',
  _ => 'Unavailable',
};

String _dateTime(DateTime date) =>
    '${_month(date.month)} ${date.day}, ${date.year} · '
    '${date.hour % 12 == 0 ? 12 : date.hour % 12}:'
    '${date.minute.toString().padLeft(2, '0')} ${date.hour < 12 ? 'AM' : 'PM'}';

String _month(int month) => const [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
][month - 1];
