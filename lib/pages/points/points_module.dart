import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/points/points_page.dart';

final pointsModule = createModule(
  path: '/points',
  register: (c) {
    c..route(
        '/',
        transition: TransitionType.none,
        child: (context, state) => const PointsPage(),
      );
  },
);