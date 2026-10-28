#!/usr/bin/env python3
"""Generates fixtures/office/rich-text.xlsx: cells whose text mixes formats (part red, part
bold, a larger run, a theme colour), on a fill and inside a merged area like real templates.
Run: python3 scripts/gen-richtext-fixture.py"""
from pathlib import Path

from openpyxl import Workbook
from openpyxl.cell.rich_text import CellRichText, TextBlock
from openpyxl.cell.text import InlineFont
from openpyxl.styles import Alignment, PatternFill

root = Path(__file__).resolve().parent.parent
out = root / "fixtures/office/rich-text.xlsx"
wb = Workbook()
ws = wb.active
ws.title = "字段清单"
red = InlineFont(color="FFC00000", sz=11)
black = InlineFont(color="FF000000", sz=11)
ws["A1"] = "所需字段"
ws["B2"] = CellRichText(
    TextBlock(black, "入库批次、生产日期、过期日期\n"),
    TextBlock(red, "单据编号"), TextBlock(black, "、"), TextBlock(red, "业务类型\n"),
    TextBlock(red, "删除标记、创建时间"),
)
ws.merge_cells("B2:F2")
ws["B2"].fill = PatternFill("solid", fgColor="FFFFB000")
ws["B2"].alignment = Alignment(wrap_text=True, vertical="center")
ws.row_dimensions[2].height = 70
ws["B4"] = CellRichText(
    "普通开头，", TextBlock(InlineFont(b=True), "加粗"), "，",
    TextBlock(InlineFont(sz=16), "大号"), "，",
    TextBlock(InlineFont(color=None, i=True), "斜体"),
)
wb.save(out)

# openpyxl writes rich text inline (<is>); Excel and most tools put it in the shared-strings
# table instead. Move B2 there so both ways are covered (B4 stays inline).
import re
import zipfile

with zipfile.ZipFile(out) as z:
    files = {n: z.read(n) for n in z.namelist()}
sheet = files["xl/worksheets/sheet1.xml"].decode()
m = re.search(r'<c r="B2"([^>]*) t="inlineStr"><is>(.*?)</is></c>', sheet, re.S)
sheet = sheet[:m.start()] + f'<c r="B2"{m.group(1)} t="s"><v>0</v></c>' + sheet[m.end():]
files["xl/worksheets/sheet1.xml"] = sheet.encode()
files["xl/sharedStrings.xml"] = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="1" uniqueCount="1">'
    f'<si>{m.group(2)}</si></sst>').encode()
ct = files["[Content_Types].xml"].decode()
ct = ct.replace("</Types>", '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>')
files["[Content_Types].xml"] = ct.encode()
rels = files["xl/_rels/workbook.xml.rels"].decode()
rels = rels.replace("</Relationships>", '<Relationship Id="rIdSS" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>')
files["xl/_rels/workbook.xml.rels"] = rels.encode()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for n, d in files.items():
        z.writestr(n, d)
print(out)
