import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/points/points_page.dart';

final pointsModule = createModule(
  path: '/points',
  register: (c) {
    c..route('/', child: (context, state) => const PointsPage());
  },
);