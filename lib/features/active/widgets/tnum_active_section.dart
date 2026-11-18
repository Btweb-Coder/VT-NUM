import 'package:flutter/material.dart';

import '../../../app/localization/app_localizations.dart';
import '../../activate/data/tnum_repository.dart';
import '../../activate/widgets/tnum_feedback.dart';
import '../../onboarding/first_time_app_guide.dart';
import '../../orders/pages/tnum_operation_details_page.dart';

class TnumActiveSection extends StatefulWidget {
  const TnumActiveSection({
    super.key,
    this.guideAnchorEnabled = true,
  });

  final bool guideAnchorEnabled;

  @override
  State<TnumActiveSection> createState() => _TnumActiveSectionState();
}

class _TnumActiveSectionState extends State<TnumActiveSection> {
  late Future<List<Map<String, dynamic>>> _activations = TnumRepository()
      .activations();

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, dynamic>>>(
    future: _activations,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        final message = TnumFeedbackMessage.fromError(snapshot.error!);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            context.strings.text(message.messageKey),
            style: const TextStyle(color: Colors.orangeAccent),
          ),
        );
      }
      final rows = snapshot.data ?? const <Map<String, dynamic>>[];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.strings.text('tnum.active_title'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(
                  () => _activations = TnumRepository().activations(),
                ),
                icon: const Icon(Icons.refresh, color: Colors.white),
              ),
            ],
          ),
          if (rows.isEmpty)
            if (widget.guideAnchorEnabled)
              FirstTimeAppGuide.anchor(
                'active',
                'SMS / VERIFICATION CODE',
                Text(
                  context.strings.text('tnum.no_active'),
                  style: const TextStyle(color: Color(0xFFA5B4D0)),
                ),
              )
            else
              Text(
                context.strings.text('tnum.no_active'),
                style: const TextStyle(color: Color(0xFFA5B4D0)),
              ),
          ...rows.asMap().entries.map((entry) {
            final row = entry.value;
            final service = Map<String, dynamic>.from(
              row['services'] as Map? ?? {},
            );
            final country = Map<String, dynamic>.from(
              row['countries'] as Map? ?? {},
            );
            final id = '${row['id']}';
            final card = Card(
              color: const Color(0xFF151D36),
              child: ListTile(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TnumOperationDetailsPage(activationId: id),
                  ),
                ),
                leading: const CircleAvatar(child: Text('T')),
                title: Text(
                  '${service['name'] ?? row['service_slug']}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                subtitle: Text(
                  '${context.strings.text('tnum.origin')} · ${country['name'] ?? row['country_code']} · ${tnumStatusLabel(context, '${row['status'] ?? ''}') }',
                  style: const TextStyle(color: Color(0xFFA5B4D0)),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Color(0xFFA5B4D0),
                ),
              ),
            );
            return entry.key == 0 && widget.guideAnchorEnabled
                ? FirstTimeAppGuide.anchor(
                    'active',
                    'SMS / VERIFICATION CODE',
                    card,
                  )
                : card;
          }),
        ],
      );
    },
  );
}
