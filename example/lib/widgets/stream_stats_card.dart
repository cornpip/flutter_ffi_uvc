import 'package:flutter/material.dart';
import 'package:flutter_ffi_uvc/flutter_ffi_uvc.dart';

import '../app_theme.dart';

class StreamStatsCard extends StatelessWidget {
  const StreamStatsCard({super.key, required this.stats});

  final UvcStreamStats stats;

  String _formatStatDouble(double value, {int fractionDigits = 1}) {
    if (value <= 0) {
      return '-';
    }
    return value.toStringAsFixed(fractionDigits);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<_StatsChipItem> chipItems = <_StatsChipItem>[
      _StatsChipItem(
        label: 'Warmup drop',
        value: '${stats.warmupDropCount}',
      ),
      _StatsChipItem(
        label: 'Callback drop',
        value: '${stats.callbackLockDropCount}',
      ),
      _StatsChipItem(label: 'Stale', value: '${stats.staleFrameCount}'),
      _StatsChipItem(
        label: 'Invalid MJPEG',
        value: '${stats.invalidMjpegCount}',
      ),
      _StatsChipItem(
        label: 'Undersized',
        value: '${stats.undersizedFrameCount}',
      ),
      _StatsChipItem(
        label: 'Convert fail',
        value: '${stats.conversionFailureCount}',
      ),
      _StatsChipItem(
        label: 'Alloc fail',
        value: '${stats.bufferAllocationFailureCount}',
      ),
      _StatsChipItem(
        label: 'Surface fail',
        value: '${stats.previewSurfaceFailureCount}',
      ),
      _StatsChipItem(
        label: 'Elapsed',
        value: '${stats.elapsed.inMilliseconds} ms',
      ),
    ].where((_StatsChipItem item) => item.visible).toList();

    Widget metric(String label, String value) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: brandGreenBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Stream Stats',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Session snapshot from the native stream pipeline.',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              metric('Input FPS', _formatStatDouble(stats.inputFps)),
              const SizedBox(width: 12),
              metric('Delivered FPS', _formatStatDouble(stats.deliveredFps)),
              const SizedBox(width: 12),
              metric(
                'First Frame',
                '${_formatStatDouble(stats.firstFrameLatencyMs)} ms',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              metric('Input', '${stats.inputFrameCount}'),
              const SizedBox(width: 12),
              metric('Delivered', '${stats.deliveredFrameCount}'),
              const SizedBox(width: 12),
              metric('Decode Fail', '${stats.decodeFailureCount}'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              metric(
                'Gap Avg',
                '${_formatStatDouble(stats.avgInterFrameGapMs)} ms',
              ),
              const SizedBox(width: 12),
              metric(
                'Gap P95',
                '${_formatStatDouble(stats.p95InterFrameGapMs)} ms',
              ),
              const SizedBox(width: 12),
              metric(
                'Gap Max',
                '${_formatStatDouble(stats.maxInterFrameGapMs)} ms',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chipItems
                .map(
                  (_StatsChipItem item) =>
                      _StatsChip(label: item.label, value: item.value),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _StatsChip extends StatelessWidget {
  const _StatsChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: brandGreenLight,
        border: Border.all(color: brandGreenBorder),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Colors.black87,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _StatsChipItem {
  const _StatsChipItem({
    required this.label,
    required this.value,
    this.visible = true,
  });

  final String label;
  final String value;
  final bool visible;
}
