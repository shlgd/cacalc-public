#!/usr/bin/env python3
"""Synthetic grammar stress cases, NOT a corpus of spontaneous human speech."""
import json, random, sys
r = random.Random(20260915)
foods = ['яблоко', 'банан', 'огурец', 'молоко 1%', 'гречка агроальянс',
         'кукурузные хлопья любятово', 'яичный белок', 'творог без сахара',
         'яблочный сок', 'куриная грудка', 'сыр гауда', 'рис вареный']
amounts = [('100', '100'), ('сто пятьдесят', '150'), ('двести', '200'),
           ('350', '350'), ('12,5', '12.5'), ('пятьдесят пять', '55'), ('триста двадцать', '320')]
units = [('грамм', 'g'), ('грамма', 'g'), ('гр', 'g'), ('миллилитров', 'ml'), ('килограмма', 'kg')]
cases = []
for i in range(5000):
    count = r.randint(1, 5)
    selected = r.sample(foods, count)
    rows, pieces = [], []
    trigger = i % 2 == 0
    for food in selected:
        spoken, value = r.choice(amounts)
        unit, code = r.choice(units)
        quantity = f'{spoken} {unit}'
        piece = f'{food} {quantity}' if r.randrange(2) else f'{quantity} {food}'
        if r.randrange(3) == 0: piece = 'ну добавляю ' + piece
        pieces.append(piece)
        rows.append({'food': food, 'quantity': value, 'unit': code})
    cases.append({'category': 'trigger' if trigger else 'mixed-order',
                  'text': (' дальше ' if trigger else ' ').join(pieces), 'rows': rows, 'pending': False})
# Frozen separately from the generator: heterogeneous edge cases and abstentions.
manual = [
 ('350 грамм яблок банан 100 грамм', [('яблок','350','g'),('банан','100','g')], False),
 ('молоко один процент триста грамм', [('молоко 1%','300','g')], False),
 ('молоко один процент', [], True),
 ('молоко один процент двести', [('молоко 1%','200','g')], False),
 ('яблоко банан 100 грамм', [], True),
 ('350 грамм', [], True),
 ('банан 100 грамм дальше', [('банан','100','g')], False),
 ('банан 100 грамм нет 150 грамм', [('банан','150','g')], False),
 ('банан 100 грамм вернее двести', [('банан','200','g')], False),
 ('не банан а яблоко 100 грамм', [], True),
 ('молоко -100 грамм', [], True),
 ('молоко 0 грамм', [], True),
 ('гречка агро альянс 150 грамм', [('гречка агро альянс','150','g')], False),
 ('суп неизвестный 120 грамм дальше банан 200 грамм', [('суп неизвестный','120','g'),('банан','200','g')], False),
 ('кукурузные хлопья любятово сто грамм ну вот я не понимаю', [('кукурузные хлопья любятово','100','g')], True),
 ('двести грамм яичного белка дальше сто грамм огурца', [('яичного белка','200','g'),('огурца','100','g')], False),
 ('банан сто пятьдеграмм', [], True),
 ('банан сто пятьдесят грамм', [('банан','150','g')], False),
 ('банан 100 грамм огурец', [('банан','100','g')], True),
 ('банан 100 грамм 200 грамм', [], True),
 ('яблоко 100 грамм банан 200 грамм молоко 1% 300 грамм', [('яблоко','100','g'),('банан','200','g'),('молоко 1%','300','g')], False),
]
for text, rows, pending in manual:
    cases.append({'category':'challenge', 'text':text,
                  'rows':[dict(zip(('food','quantity','unit'), row)) for row in rows], 'pending':pending})
json.dump({'foods': foods, 'cases': cases}, sys.stdout, ensure_ascii=False)
