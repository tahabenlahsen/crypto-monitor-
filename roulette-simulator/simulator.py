#!/usr/bin/env python3
"""
محاكي روليت تعليمي — هل يمكن توقع الأحمر/الأسود من الإحصائيات السابقة؟
Educational roulette simulator: can past statistics predict red/black?

يولّد هذا السكريبت آلاف دورات روليت أوروبي (نفس آلية RNG المستخدمة في
الكازيоноهات الرقمية)، ثم يجرّب استراتيجيات "التوقع بالإحصائيات" الشهيرة
ويقيس دقتها الفعلية وأثرها على رصيد اللاعب.

النتيجة المتوقعة رياضيًا: كل الاستراتيجيات تحقق دقة ≈ 48.65%
(18/37) مهما كانت ذكية، لأن كل دورة مستقلة عن السابقة.

Usage:
    python3 simulator.py [--spins 100000] [--seed 42]
"""

import argparse
import random
from dataclasses import dataclass, field

# European wheel: 0 is green, 18 red, 18 black
RED = {1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36}
BLACK = {2, 4, 6, 8, 10, 11, 13, 15, 17, 20, 22, 24, 26, 28, 29, 31, 33, 35}

# احتمال فوز أي رهان على لون واحد = 18/37
THEORETICAL_WIN_RATE = 18 / 37  # ≈ 0.4865


def color_of(n: int) -> str:
    if n == 0:
        return "green"
    return "red" if n in RED else "black"


# ---------------------------------------------------------------------------
# الاستراتيجيات: كل واحدة تأخذ تاريخ الألوان السابقة وتتوقع اللون القادم
# ---------------------------------------------------------------------------

def strat_random(history: list[str]) -> str:
    """خط الأساس: توقع عشوائي بحت."""
    return random.choice(["red", "black"])


def strat_follow_streak(history: list[str]) -> str:
    """اتبع الموجة: راهن على آخر لون ظهر ("اللون الساخن")."""
    for c in reversed(history):
        if c != "green":
            return c
    return "red"


def strat_against_streak(history: list[str]) -> str:
    """مغالطة المقامر: إذا ظهر الأحمر كثيرًا فالأسود 'مستحق' — راهن ضد آخر لون."""
    for c in reversed(history):
        if c != "green":
            return "black" if c == "red" else "red"
    return "red"


def strat_bet_on_rarer(history: list[str], window: int = 50) -> str:
    """التعويض: راهن على اللون الأقل ظهورًا في آخر 50 دورة (يفترض أنه 'سيعوّض')."""
    recent = [c for c in history[-window:] if c != "green"]
    if not recent:
        return "red"
    reds = sum(1 for c in recent if c == "red")
    return "black" if reds > len(recent) - reds else "red"


def strat_bet_on_hotter(history: list[str], window: int = 50) -> str:
    """اللون الساخن: راهن على اللون الأكثر ظهورًا في آخر 50 دورة."""
    recent = [c for c in history[-window:] if c != "green"]
    if not recent:
        return "red"
    reds = sum(1 for c in recent if c == "red")
    return "red" if reds > len(recent) - reds else "black"


def strat_wait_for_streak(history: list[str], streak_len: int = 5) -> str | None:
    """الانتظار الانتقائي: لا تراهن إلا بعد 5 تكرارات متتالية لنفس اللون،
    ثم راهن على اللون المعاكس. (None = لا رهان في هذه الدورة)"""
    if len(history) < streak_len:
        return None
    tail = history[-streak_len:]
    if all(c == "red" for c in tail):
        return "black"
    if all(c == "black" for c in tail):
        return "red"
    return None


STRATEGIES = {
    "توقع عشوائي (خط الأساس)": strat_random,
    "اتبع آخر لون (الموجة الساخنة)": strat_follow_streak,
    "راهن ضد آخر لون (مغالطة المقامر)": strat_against_streak,
    "راهن على اللون الأقل في آخر 50": strat_bet_on_rarer,
    "راهن على اللون الأكثر في آخر 50": strat_bet_on_hotter,
    "انتظر 5 تكرارات ثم راهن بالعكس": strat_wait_for_streak,
}


# ---------------------------------------------------------------------------
# المحاكاة
# ---------------------------------------------------------------------------

@dataclass
class Result:
    name: str
    bets: int = 0
    wins: int = 0
    bankroll: float = 1000.0  # يبدأ اللاعب بـ 1000 وحدة، رهان ثابت 10
    history_bankroll: list[float] = field(default_factory=list)

    @property
    def accuracy(self) -> float:
        return self.wins / self.bets if self.bets else 0.0


def run(spins: int, seed: int | None) -> tuple[list[str], list[Result]]:
    rng = random.Random(seed)
    outcomes = [color_of(rng.randint(0, 36)) for _ in range(spins)]

    results = []
    for name, strat in STRATEGIES.items():
        random.seed(seed)  # لعدالة المقارنة مع الاستراتيجية العشوائية
        res = Result(name=name)
        history: list[str] = []
        for outcome in outcomes:
            prediction = strat(history)
            if prediction is not None:
                res.bets += 1
                if prediction == outcome:
                    res.wins += 1
                    res.bankroll += 10  # الرهان على اللون يدفع 1:1
                else:
                    res.bankroll -= 10
                res.history_bankroll.append(res.bankroll)
            history.append(outcome)
        results.append(res)
    return outcomes, results


def martingale_demo(spins: int, seed: int | None) -> None:
    """عرض منفصل: استراتيجية المضاعفة (Martingale) — مضاعفة الرهان بعد كل خسارة.
    تبدو مربحة قصيرًا ثم تنتهي بالإفلاس عند أول سلسلة خسائر طويلة."""
    rng = random.Random(seed)
    bankroll, base_bet, bet = 1000.0, 10.0, 10.0
    peak, ruined_at = bankroll, None
    for i in range(spins):
        if bet > bankroll:
            ruined_at = i
            break
        outcome = color_of(rng.randint(0, 36))
        if outcome == "red":
            bankroll += bet
            bet = base_bet
        else:
            bankroll -= bet
            bet *= 2
        peak = max(peak, bankroll)

    print("\n── استراتيجية المضاعفة (Martingale): راهن على الأحمر وضاعف بعد كل خسارة ──")
    print(f"  البداية: 1000 وحدة | أعلى رصيد وصله: {peak:.0f}")
    if ruined_at is not None:
        print(f"  ⚠️  أفلس اللاعب في الدورة رقم {ruined_at}: "
              f"الرصيد المتبقي ({bankroll:.0f}) لا يكفي للرهان المطلوب ({bet:.0f})")
        print("  سلسلة خسائر واحدة طويلة تمحو كل الأرباح الصغيرة السابقة.")
    else:
        print(f"  الرصيد النهائي بعد {spins} دورة: {bankroll:.0f} (نجا هذه المرة — جرّب seed آخر)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spins", type=int, default=100_000, help="عدد الدورات")
    parser.add_argument("--seed", type=int, default=None, help="بذرة العشوائية (للتكرار)")
    args = parser.parse_args()

    outcomes, results = run(args.spins, args.seed)

    reds = sum(1 for c in outcomes if c == "red")
    blacks = sum(1 for c in outcomes if c == "black")
    greens = sum(1 for c in outcomes if c == "green")

    print(f"═══ محاكاة {args.spins:,} دورة روليت أوروبي ═══")
    print(f"أحمر: {reds:,} ({reds/args.spins:.2%}) | "
          f"أسود: {blacks:,} ({blacks/args.spins:.2%}) | "
          f"أخضر (0): {greens:,} ({greens/args.spins:.2%})")
    print(f"\nالدقة النظرية القصوى لأي توقع أحمر/أسود: {THEORETICAL_WIN_RATE:.2%}")
    print("(أي استراتيجية تظهر قريبًا من هذا الرقم لا تملك أي 'قدرة توقع' حقيقية)\n")

    header = f"{'الاستراتيجية':<38} {'الرهانات':>10} {'الدقة':>8} {'الرصيد النهائي':>14}"
    print(header)
    print("─" * len(header))
    for r in results:
        profit = r.bankroll - 1000
        sign = "+" if profit >= 0 else ""
        print(f"{r.name:<38} {r.bets:>10,} {r.accuracy:>8.2%} "
              f"{r.bankroll:>10.0f} ({sign}{profit:.0f})")

    martingale_demo(args.spins, args.seed)

    print("\n═══ الخلاصة ═══")
    print("كل الاستراتيجيات — مهما بدت ذكية — تحوم حول 48.65% بالضبط.")
    print("الفارق بين 48.65% و50% هو الصفر الأخضر: هذه هي 'أفضلية الكازينو' (2.7%)")
    print("وهي رياضيًا غير قابلة للتجاوز بأي قراءة للإحصائيات السابقة،")
    print("لأن كل دورة حدث مستقل تمامًا. الإحصائيات المعروضة على شاشة")
    print("الكازينو موجودة لتشجيعك على الرهان — لا لمساعدتك.")


if __name__ == "__main__":
    main()
