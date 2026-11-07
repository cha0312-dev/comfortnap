import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';

class WeeklySleepScreen extends StatefulWidget {
  final DateTime selectedDate;

  const WeeklySleepScreen({super.key, required this.selectedDate});

  @override
  State<WeeklySleepScreen> createState() => _WeeklySleepScreenState();
}

class _WeeklySleepScreenState extends State<WeeklySleepScreen> {
  late DateTime weekStart;
  late DateTime weekEnd;
  Widget buildBarChart() {
    return Container(
      height: 250,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
      ),
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: dailySleep.isNotEmpty
              ? dailySleep.reduce((a, b) => a > b ? a : b) / 3600 + 2
              : 10,

          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 35,
                getTitlesWidget: (value, meta) {
                  return Text(
                    value.toInt().toString(),
                    style: const TextStyle(color: Colors.white70, fontSize: 10),
                  );
                },
              ),
            ),

            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),

            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),

            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  return Text(
                    days[value.toInt()],
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  );
                },
              ),
            ),
          ),

          borderData: FlBorderData(show: false),

          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 2,
          ),

          barGroups: List.generate(
            7,
            (i) => BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: dailySleep[i] / 3600,
                  width: 18,
                  borderRadius: BorderRadius.circular(6),
                  color: dailySleep[i] >= 8 * 3600
                      ? Colors.greenAccent
                      : dailySleep[i] >= 6 * 3600
                      ? Colors.cyanAccent
                      : Colors.orangeAccent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<int> dailySleep = List.filled(7, 0);
  int totalSleep = 0;
  bool isLoading = true;

  final List<String> days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

  @override
  void initState() {
    super.initState();

    weekStart = widget.selectedDate.subtract(
      Duration(days: widget.selectedDate.weekday % 7),
    );

    weekEnd = weekStart.add(const Duration(days: 6));

    loadWeeklyData();
  }

  Future<void> loadWeeklyData() async {
    setState(() => isLoading = true);

    final snapshot = await FirebaseFirestore.instance
        .collection("vibrator_logs")
        .where("timestamp", isGreaterThanOrEqualTo: weekStart)
        .where("timestamp", isLessThanOrEqualTo: weekEnd)
        .get();

    List<int> temp = List.filled(7, 0);
    int total = 0;

    for (var doc in snapshot.docs) {
      final data = doc.data();

      final ts = data["timestamp"] as Timestamp;
      final date = ts.toDate();

      int index = date.weekday % 7;
      int duration = (data["duration"] ?? 0) as int;

      temp[index] += duration;
      total += duration;
    }

    setState(() {
      dailySleep = temp;
      totalSleep = total;
      isLoading = false;
    });
  }

  String formatDuration(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;

    return "${h}h ${m}m ${s}s";
  }

  Widget buildSleepCard(int i) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            days[i],
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text(
            formatDuration(dailySleep[i]),
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(Color color, String text) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF07051F),

      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 🔙 HEADER
              Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),

                  const SizedBox(width: 15),

                  const Text(
                    "Weekly Sleep",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 20),

              // 📅 DATE RANGE CARD
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.cyanAccent.withOpacity(0.2),
                      Colors.blueAccent.withOpacity(0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  "${DateFormat('MMM d').format(weekStart)} - ${DateFormat('MMM d').format(weekEnd)}",
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 15,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ⏱ TOTAL SLEEP
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Total Sleep",
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    Text(
                      formatDuration(totalSleep),
                      style: const TextStyle(
                        color: Colors.cyanAccent,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 25),
              const Text(
                "Sleep Trend",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 12),

              buildBarChart(),
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _legend(Colors.greenAccent, "8h+"),
                  _legend(Colors.cyanAccent, "6-8h"),
                  _legend(Colors.orangeAccent, "<6h"),
                ],
              ),

              const SizedBox(height: 25),

              // 📊 LIST
              Expanded(
                child: isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: Colors.cyanAccent,
                        ),
                      )
                    : ListView.builder(
                        itemCount: 7,
                        itemBuilder: (context, i) => buildSleepCard(i),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
