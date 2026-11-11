"""Builds financial_model_template.xlsx (no fabricated figures: every input is 0 / blank)."""
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
import os

OUT = os.path.join(os.path.dirname(__file__), '..', 'financial_model_template.xlsx')
TEAL, AMBER, OFF = '2B7A8C', 'D9822B', 'F6F4F0'
hdr_font = Font(bold=True, color='FFFFFF', name='Calibri')
hdr_fill = PatternFill('solid', fgColor=TEAL)
inp_fill = PatternFill('solid', fgColor='FFF4E5')   # input cells (amber tint)
sec_fill = PatternFill('solid', fgColor='D7ECEF')
thin = Side(style='thin', color='E3DED6')
box = Border(left=thin, right=thin, top=thin, bottom=thin)
MONTHS = 36

wb = Workbook()

# ---------------------------------------------------------------- README
ws = wb.active; ws.title = 'README'
lines = [
 ('CoRoute financial model template (36 months, monthly)', True),
 ('Prepared 11 Nov 2026. CoRoute is pre-launch: there is NO actual data in this file.', False),
 ('', False),
 ('How to use', True),
 ('1. Fill the amber cells in column C of the Assumptions sheet. Every input starts at 0 so the model shows 0 until you fill it.', False),
 ('2. Column E ("Example / code default") is for reference only. No formula reads it. Values there come only from the CoRoute code defaults (e.g. plan list prices, seats, SMS caps); everything else says what to put.', False),
 ('3. Users funnel, Revenue, Costs and P&L are formulas only. Do not type over them.', False),
 ('4. Label any output you share as "model, based on assumptions", never as traction.', False),
 ('', False),
 ('Sheets', True),
 ('Assumptions: all inputs with units and notes.', False),
 ('Users funnel: installs -> sign-ups -> monthly active riders -> group hosts -> paying hosts; operators.', False),
 ('Revenue: group plans, operators, partner perks.', False),
 ('Costs: infrastructure, SMS per SOS, e-mail, payment fees, marketing, team, other fixed.', False),
 ('P&L: monthly revenue, cost of revenue, gross profit, operating costs, EBITDA, cash balance; yearly totals at the bottom.', False),
 ('', False),
 ('Model logic (simplified)', True),
 ('Installs(m) = Installs month 1 x (1 + monthly growth)^(m-1)', False),
 ('Active riders(m) = Active riders(m-1) x (1 - monthly churn) + Sign-ups(m) x activation rate', False),
 ('Paying hosts(m) = Active riders x host share x paid conversion, only from the month paid hosting starts (access mode Paid / Free up to limits)', False),
 ('Plan ARPU = (mix small x price small + (1 - mix small) x price large) x (1 - average discount) x 30 / billing days', False),
 ('Server SMS(m) = Active riders / 1000 x SOS per 1000 riders x contacts per SOS x (1 + share with "safe now" text) x cost per SMS. Texts sent from riders\' own phones cost CoRoute nothing. Code caps: max 5 contacts per SOS, 20 SOS texts per rider per day.', False),
 ('Push notifications (Firebase Cloud Messaging) have no per-message charge, so they are not a cost line.', False),
]
for i, (t, b) in enumerate(lines, 1):
    c = ws.cell(row=i, column=1, value=t); c.font = Font(bold=b, size=14 if i == 1 else 11, color=TEAL if b else '1F2328')
    c.alignment = Alignment(wrap_text=True, vertical='top')
ws.column_dimensions['A'].width = 140

# ---------------------------------------------------------------- Assumptions
A = wb.create_sheet('Assumptions')
A.append(['Section', 'Parameter', 'Value (input)', 'Unit', 'Example / code default (not used by formulas)', 'Notes'])
for c in A[1]: c.font = hdr_font; c.fill = hdr_fill; c.alignment = Alignment(wrap_text=True, vertical='center')
rows = [
 ('Funnel', 'installs_m1', 'Installs in month 1', 0, 'installs', '[OWNER TO FILL]', 'From launch plan / Play Console after launch'),
 ('Funnel', 'install_growth', 'Monthly growth of installs', 0, '% per month', '[OWNER TO FILL]', 'Enter as a decimal (0.10 = 10 %)'),
 ('Funnel', 'signup_rate', 'Installs that create an account', 0, '%', '[OWNER TO FILL]', 'Play Console installs vs admin analytics sign-ups'),
 ('Funnel', 'activation_rate', 'Sign-ups that complete a ride in their first month', 0, '%', '[OWNER TO FILL]', 'See traction_and_kpis.md "First-ride activation"'),
 ('Funnel', 'rider_churn', 'Monthly churn of active riders', 0, '% per month', '[OWNER TO FILL]', 'Share of last month\'s active riders with no ride this month'),
 ('Funnel', 'host_share', 'Active riders who host at least one group ride a month', 0, '%', '[OWNER TO FILL]', 'Groups list by owner'),
 ('Plans', 'paid_start_month', 'First month in which hosting needs a plan', 1, 'month number (1-36)', '1 = Paid from launch', 'Access mode: Paid or Free up to limits. Set later than 36 to model "Free for everyone" throughout'),
 ('Plans', 'paid_conversion', 'Hosts on a paid plan (once paid hosting starts)', 0, '%', '[OWNER TO FILL]', 'In Free up to limits mode, only hosts above the free limits pay'),
 ('Plans', 'mix_small', 'Share of paying hosts on Small Group', 0, '%', '[OWNER TO FILL]', 'Remainder is Large Group'),
 ('Plans', 'price_small', 'Small Group list price', 0, '₹ per billing period', '49 (current default config)', 'gateway/src/oracle/repo.js _defaultMembershipCatalog; launch price is an owner decision'),
 ('Plans', 'price_large', 'Large Group list price', 0, '₹ per billing period', '99 (current default config)', 'Same source'),
 ('Plans', 'billing_days', 'Billing period', 30, 'days', '30 (current default config)', 'Plans do not auto-renew'),
 ('Plans', 'avg_discount', 'Average discount from offers and coupons', 0, '%', '[OWNER TO FILL]', 'Web admin > Revenue / Coupons'),
 ('Operators', 'ops_new', 'New paying operators per month', 0, 'operators', '[OWNER TO FILL]', 'Tour operators, clubs, rental and corporate fleets'),
 ('Operators', 'ops_start_month', 'First month operators pay', 1, 'month number', '[OWNER TO FILL]', ''),
 ('Operators', 'ops_churn', 'Monthly churn of operators', 0, '% per month', '[OWNER TO FILL]', ''),
 ('Operators', 'ops_arpu', 'Revenue per operator per month', 0, '₹ per month', '[OWNER TO FILL]', 'Pricing model decision D13 (per bike / per tour / per operator)'),
 ('Partners', 'partner_rev', 'Partner perk revenue per month', 0, '₹ per month', '[OWNER TO FILL]', 'Listing fee or per redemption; planned v3.57'),
 ('Partners', 'partner_start_month', 'First month with partner revenue', 13, 'month number', '[OWNER TO FILL]', ''),
 ('Costs', 'infra_fixed', 'Cloud infrastructure fixed cost', 0, '₹ per month', '[OWNER TO FILL]', 'Two OCI VMs, database, object storage, load balancer'),
 ('Costs', 'infra_per_1000', 'Extra infrastructure per 1,000 active riders', 0, '₹ per month', '[OWNER TO FILL]', 'Step costs once peak live riders exceed measured capacity (soak test)'),
 ('Costs', 'sos_per_1000', 'SOS / crash alerts per 1,000 active riders per month', 0, 'alerts', '[OWNER TO FILL]', 'Admin analytics safety.sosInPeriod after launch'),
 ('Costs', 'contacts_per_sos', 'Server SMS contacts per SOS', 0, 'contacts', 'max 5 (code cap)', 'sos_sms.md cost guard; only contacts the phone could not text'),
 ('Costs', 'safe_now_share', 'Share of SOS texts followed by a "safe now" text', 0, '%', '[OWNER TO FILL]', ''),
 ('Costs', 'sms_cost', 'Cost per server SMS', 0, '₹ per SMS', '[OWNER TO FILL]', 'MSG91 or Twilio; Indian DLT route'),
 ('Costs', 'emails_per_payer', 'Transactional e-mails per paying host per month', 0, 'e-mails', '[OWNER TO FILL]', 'Receipts, refunds; offer e-mails only to opted-in riders'),
 ('Costs', 'email_cost', 'Cost per e-mail', 0, '₹ per e-mail', '[OWNER TO FILL]', 'SMTP provider'),
 ('Costs', 'payment_fee', 'Payment gateway fee on website revenue', 0, '% of revenue', '[OWNER TO FILL]', 'Razorpay agreement'),
 ('Costs', 'marketing', 'Marketing and community spend', 0, '₹ per month', '[OWNER TO FILL]', 'Clubs, content, creators, events'),
 ('Costs', 'headcount', 'Team headcount', 0, 'people', '[OWNER TO FILL]', ''),
 ('Costs', 'cost_per_head', 'Fully loaded cost per person', 0, '₹ per month', '[OWNER TO FILL]', ''),
 ('Costs', 'other_fixed', 'Other fixed costs', 0, '₹ per month', '[OWNER TO FILL]', 'Legal, accounting, tools, store accounts, devices'),
 ('Cash', 'opening_cash', 'Cash at the start of month 1', 0, '₹', '[OWNER TO FILL]', 'Include any committed funding only once received'),
]
NAME = {}
section = None
r = 2
for sec, key, label, val, unit, ex, note in rows:
    A.cell(row=r, column=1, value=sec if sec != section else None).font = Font(bold=True, color=TEAL)
    section = sec
    A.cell(row=r, column=2, value=label)
    c = A.cell(row=r, column=3, value=val); c.fill = inp_fill
    if unit.startswith('%'): c.number_format = '0.0%'
    elif '₹' in unit: c.number_format = '#,##0'
    A.cell(row=r, column=4, value=unit)
    A.cell(row=r, column=5, value=ex).font = Font(italic=True, color='5B616B')
    A.cell(row=r, column=6, value=note).alignment = Alignment(wrap_text=True)
    for col in range(1, 7): A.cell(row=r, column=col).border = box
    NAME[key] = f"Assumptions!$C${r}"
    r += 1
for col, w in zip('ABCDEF', (12, 52, 16, 20, 30, 70)): A.column_dimensions[col].width = w
A.freeze_panes = 'C2'

def sheet(title, headers, widths=None):
    s = wb.create_sheet(title)
    s.append(headers)
    for c in s[1]: c.font = hdr_font; c.fill = hdr_fill; c.alignment = Alignment(wrap_text=True, vertical='center', horizontal='center')
    s.row_dimensions[1].height = 34
    for i, h in enumerate(headers, 1): s.column_dimensions[get_column_letter(i)].width = (widths or {}).get(i, 16)
    s.freeze_panes = 'B2'
    return s
N = NAME

# ---------------------------------------------------------------- Users funnel
U = sheet('Users funnel', ['Month', 'Installs', 'Sign-ups', 'New active riders', 'Active riders (MAR)', 'Group hosts', 'Paying hosts', 'Operators (active)'])
for m in range(1, MONTHS + 1):
    i = m + 1
    U.cell(row=i, column=1, value=m)
    U.cell(row=i, column=2, value=f"={N['installs_m1']}*(1+{N['install_growth']})^(A{i}-1)")
    U.cell(row=i, column=3, value=f"=B{i}*{N['signup_rate']}")
    U.cell(row=i, column=4, value=f"=C{i}*{N['activation_rate']}")
    prev = f"E{i-1}*(1-{N['rider_churn']})+" if m > 1 else ''
    U.cell(row=i, column=5, value=f"={prev}D{i}")
    U.cell(row=i, column=6, value=f"=E{i}*{N['host_share']}")
    U.cell(row=i, column=7, value=f"=IF(A{i}>={N['paid_start_month']},F{i}*{N['paid_conversion']},0)")
    prevo = f"H{i-1}*(1-{N['ops_churn']})+" if m > 1 else ''
    U.cell(row=i, column=8, value=f"={prevo}IF(A{i}>={N['ops_start_month']},{N['ops_new']},0)")
    for col in range(2, 9): U.cell(row=i, column=col).number_format = '#,##0'

# ---------------------------------------------------------------- Revenue
R = sheet('Revenue', ['Month', 'Plan ARPU (₹/paying host/month)', 'Group plan revenue (₹)', 'Operator revenue (₹)', 'Partner revenue (₹)', 'Total revenue (₹)'])
for m in range(1, MONTHS + 1):
    i = m + 1
    R.cell(row=i, column=1, value=m)
    R.cell(row=i, column=2, value=f"=IF({N['billing_days']}>0,({N['mix_small']}*{N['price_small']}+(1-{N['mix_small']})*{N['price_large']})*(1-{N['avg_discount']})*30/{N['billing_days']},0)")
    R.cell(row=i, column=3, value=f"='Users funnel'!G{i}*B{i}")
    R.cell(row=i, column=4, value=f"='Users funnel'!H{i}*{N['ops_arpu']}")
    R.cell(row=i, column=5, value=f"=IF(A{i}>={N['partner_start_month']},{N['partner_rev']},0)")
    R.cell(row=i, column=6, value=f"=C{i}+D{i}+E{i}")
    for col in range(2, 7): R.cell(row=i, column=col).number_format = '#,##0'

# ---------------------------------------------------------------- Costs
C = sheet('Costs', ['Month', 'Infrastructure (₹)', 'Server SMS for SOS (₹)', 'E-mail (₹)', 'Payment fees (₹)', 'Marketing (₹)', 'Team (₹)', 'Other fixed (₹)', 'Total costs (₹)', 'Server SMS sent'])
for m in range(1, MONTHS + 1):
    i = m + 1
    C.cell(row=i, column=1, value=m)
    C.cell(row=i, column=2, value=f"={N['infra_fixed']}+'Users funnel'!E{i}/1000*{N['infra_per_1000']}")
    C.cell(row=i, column=10, value=f"='Users funnel'!E{i}/1000*{N['sos_per_1000']}*{N['contacts_per_sos']}*(1+{N['safe_now_share']})")
    C.cell(row=i, column=3, value=f"=J{i}*{N['sms_cost']}")
    C.cell(row=i, column=4, value=f"='Users funnel'!G{i}*{N['emails_per_payer']}*{N['email_cost']}")
    C.cell(row=i, column=5, value=f"=Revenue!C{i}*{N['payment_fee']}")
    C.cell(row=i, column=6, value=f"={N['marketing']}")
    C.cell(row=i, column=7, value=f"={N['headcount']}*{N['cost_per_head']}")
    C.cell(row=i, column=8, value=f"={N['other_fixed']}")
    C.cell(row=i, column=9, value=f"=SUM(B{i}:H{i})")
    for col in range(2, 11): C.cell(row=i, column=col).number_format = '#,##0'

# ---------------------------------------------------------------- P&L
P = sheet('P&L', ['Month', 'Revenue (₹)', 'Cost of revenue (₹)', 'Gross profit (₹)', 'Gross margin', 'Operating costs (₹)', 'EBITDA (₹)', 'Cash balance (₹)'])
for m in range(1, MONTHS + 1):
    i = m + 1
    P.cell(row=i, column=1, value=m)
    P.cell(row=i, column=2, value=f"=Revenue!F{i}")
    P.cell(row=i, column=3, value=f"=Costs!B{i}+Costs!C{i}+Costs!D{i}+Costs!E{i}")
    P.cell(row=i, column=4, value=f"=B{i}-C{i}")
    P.cell(row=i, column=5, value=f"=IF(B{i}=0,0,D{i}/B{i})"); P.cell(row=i, column=5).number_format = '0.0%'
    P.cell(row=i, column=6, value=f"=Costs!F{i}+Costs!G{i}+Costs!H{i}")
    P.cell(row=i, column=7, value=f"=D{i}-F{i}")
    prevc = f"H{i-1}" if m > 1 else N['opening_cash']
    P.cell(row=i, column=8, value=f"={prevc}+G{i}")
    for col in (2, 3, 4, 6, 7, 8): P.cell(row=i, column=col).number_format = '#,##0;[Red]-#,##0'
# yearly totals
base = MONTHS + 3
P.cell(row=base, column=1, value='Yearly totals').font = Font(bold=True, color=TEAL)
P.cell(row=base + 1, column=1, value='Year'); 
for j, h in enumerate(['Revenue (₹)', 'Cost of revenue (₹)', 'Gross profit (₹)', 'Gross margin', 'Operating costs (₹)', 'EBITDA (₹)', 'Cash at year end (₹)'], 2):
    c = P.cell(row=base + 1, column=j, value=h); c.font = Font(bold=True); c.fill = sec_fill
P.cell(row=base + 1, column=1).font = Font(bold=True); P.cell(row=base + 1, column=1).fill = sec_fill
for y in range(1, 4):
    rr = base + 1 + y; a, b = 2 + (y - 1) * 12, 13 + (y - 1) * 12
    P.cell(row=rr, column=1, value=y)
    for col, L in ((2, 'B'), (3, 'C'), (4, 'D'), (6, 'F'), (7, 'G')):
        P.cell(row=rr, column=col, value=f"=SUM({L}{a}:{L}{b})").number_format = '#,##0;[Red]-#,##0'
    P.cell(row=rr, column=5, value=f"=IF(B{rr}=0,0,D{rr}/B{rr})").number_format = '0.0%'
    P.cell(row=rr, column=8, value=f"=H{b}").number_format = '#,##0;[Red]-#,##0'

# Unit economics (derived)
E = sheet('Unit economics', ['Metric', 'Formula / value', 'Notes'], {1: 40, 2: 22, 3: 70})
ue = [
 ('Plan ARPU (₹ / paying host / month)', '=Revenue!B2', 'From Assumptions'),
 ('Gross margin, month 36', "='P&L'!E37", ''),
 ('Paid CAC (₹) [OWNER TO FILL]', 0, 'Marketing + sales spend / new paying hosts'),
 ('Monthly paid churn [OWNER TO FILL]', 0, 'Share of paying hosts who do not buy again'),
 ('LTV of a paying host (₹)', '=IF(B5=0,0,B2*B3/B5)', 'ARPU x gross margin / monthly paid churn'),
 ('Payback (months)', '=IF(B2*B3=0,0,B4/(B2*B3))', 'Paid CAC / (ARPU x gross margin)'),
]
for k, (m_, f, n_) in enumerate(ue, 2):
    E.cell(row=k, column=1, value=m_); c = E.cell(row=k, column=2, value=f); E.cell(row=k, column=3, value=n_)
    if isinstance(f, int): c.fill = inp_fill
E['B3'].number_format = '0.0%'; E['B5'].number_format = '0.0%'

wb.calculation.fullCalcOnLoad = True
wb.save(OUT)
print('saved', os.path.abspath(OUT))
