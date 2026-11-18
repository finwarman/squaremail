#!/usr/bin/env python3
"""Generate disposable image/PDF email. No network access."""
import io, struct, sys, zlib, zipfile
from email.message import EmailMessage

def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))

png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 3200, 2400, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress((b'\0' + b'\x20\x60\xc0' * 3200) * 2400)) + chunk(b'IEND', b'')
stream = b'0.1 0.3 0.7 rg 10 10 180 120 re f'
objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 140] /Resources << >> /Contents 4 0 R >>',
           b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
pdf = b'%PDF-1.4\n'; offsets = [0]
for index, obj in enumerate(objects, 1):
    offsets.append(len(pdf)); pdf += str(index).encode() + b' 0 obj\n' + obj + b'\nendobj\n'
xref = len(pdf)
pdf += b'xref\n0 5\n0000000000 65535 f \n' + b''.join(f'{o:010} 00000 n \n'.encode() for o in offsets[1:])
pdf += b'trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n' + str(xref).encode() + b'\n%%EOF\n'
message = EmailMessage()
message['From'] = 'Media fixture <fixture@example.test>'
message['To'] = 'reader@example.test'
message['Subject'] = 'Image and PDF preview fixture'
message.set_content('A generated image and PDF. No provider or remote network access.')
message.add_alternative('<h2>Preview fixture</h2><table height="900"><tr><td height="800"><img src="cid:photo" alt="Blue image"></td></tr></table>', subtype='html')
message.add_attachment(png, maintype='image', subtype='png', filename='blue.png', cid='<photo>')
message.add_attachment(pdf, maintype='application', subtype='pdf', filename='sample.pdf')
def office(files):
    data = io.BytesIO()
    with zipfile.ZipFile(data, 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, value in files.items():
            archive.writestr(name, value)
    return data.getvalue()

rels = 'http://schemas.openxmlformats.org/package/2006/relationships'
docrel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
docx = office({
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    '_rels/.rels': f'<Relationships xmlns="{rels}"><Relationship Id="rId1" Type="{docrel}/officeDocument" Target="word/document.xml"/></Relationships>',
    'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Square Mail native document preview</w:t></w:r></w:p></w:body></w:document>'
})
xlsx = office({
    '[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
    '_rels/.rels': f'<Relationships xmlns="{rels}"><Relationship Id="rId1" Type="{docrel}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml': f'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="{docrel}"><sheets><sheet name="Preview" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': f'<Relationships xmlns="{rels}"><Relationship Id="rId1" Type="{docrel}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/worksheets/sheet1.xml': '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Square Mail spreadsheet preview</t></is></c></row></sheetData></worksheet>'
})
message.add_attachment(docx, maintype='application', subtype='vnd.openxmlformats-officedocument.wordprocessingml.document', filename='sample.docx')
message.add_attachment(xlsx, maintype='application', subtype='vnd.openxmlformats-officedocument.spreadsheetml.sheet', filename='sample.xlsx')
open(sys.argv[1], 'wb').write(message.as_bytes())
