using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Globalization;

// Écrit un vrai fichier Excel (.xlsx) à plusieurs onglets à partir de tableaux texte (colonnes séparées par des tabulations)
public static class XlsxEcrivain
{
    static string Esc(string s) { return System.Security.SecurityElement.Escape(s); }
    static string Col(int i)
    {
        string s = ""; i++;
        while (i > 0) { int m = (i - 1) % 26; s = (char)('A' + m) + s; i = (i - 1) / 26; }
        return s;
    }
    static void Ajouter(ZipArchive z, string nom, string contenu)
    {
        var e = z.CreateEntry(nom, CompressionLevel.Optimal);
        using (var w = new StreamWriter(e.Open())) { w.Write(contenu); }
    }
    static readonly DateTime Origine = new DateTime(1899, 12, 30);

    static string Feuille(string tsv)
    {
        var sb = new StringBuilder(tsv.Length * 3);
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">");
        sb.Append("<sheetViews><sheetView workbookViewId=\"0\"><pane xSplit=\"1\" ySplit=\"1\" topLeftCell=\"B2\" activePane=\"bottomRight\" state=\"frozen\"/></sheetView></sheetViews>");
        sb.Append("<cols><col min=\"1\" max=\"1\" width=\"16\" customWidth=\"1\"/><col min=\"2\" max=\"80\" width=\"18\" customWidth=\"1\"/></cols><sheetData>");
        string[] lignes = tsv.Replace("\r", "").Split('\n');
        int r = 0;
        foreach (string ligne in lignes)
        {
            if (ligne.Length == 0 && r > 0) continue;
            r++;
            sb.Append("<row r=\"").Append(r).Append("\">");
            string[] cells = ligne.Split('\t');
            for (int c = 0; c < cells.Length; c++)
            {
                string v = cells[c];
                if (v.Length == 0) continue;
                string reff = Col(c) + r;
                double d; DateTime dt;
                if (r > 1 && v.Length == 10 && v[4] == '-' && v[7] == '-' && DateTime.TryParseExact(v, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
                    sb.Append("<c r=\"").Append(reff).Append("\" s=\"2\"><v>").Append((dt - Origine).TotalDays.ToString(CultureInfo.InvariantCulture)).Append("</v></c>");
                else if (r > 1 && v.EndsWith("%") && double.TryParse(v.Substring(0, v.Length - 1), NumberStyles.Float, CultureInfo.InvariantCulture, out d))
                    sb.Append("<c r=\"").Append(reff).Append("\" s=\"3\"><v>").Append((d / 100).ToString("R", CultureInfo.InvariantCulture)).Append("</v></c>");
                else if (r > 1 && double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out d))
                    sb.Append("<c r=\"").Append(reff).Append("\" s=\"").Append(d == Math.Floor(d) ? "4" : "0").Append("\"><v>").Append(d.ToString("R", CultureInfo.InvariantCulture)).Append("</v></c>");
                else
                    sb.Append("<c r=\"").Append(reff).Append("\" t=\"inlineStr\"").Append(r == 1 ? " s=\"1\"" : "").Append("><is><t xml:space=\"preserve\">").Append(Esc(v)).Append("</t></is></c>");
            }
            sb.Append("</row>");
        }
        sb.Append("</sheetData></worksheet>");
        return sb.ToString();
    }

    public static void Ecrire(string chemin, string[] noms, string[] tsvs)
    {
        if (File.Exists(chemin)) File.Delete(chemin);
        using (var fs = new FileStream(chemin, FileMode.Create))
        using (var z = new ZipArchive(fs, ZipArchiveMode.Create))
        {
            var ct = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>");
            var wb = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>");
            var rl = new StringBuilder("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">");
            for (int i = 0; i < noms.Length; i++)
            {
                ct.Append("<Override PartName=\"/xl/worksheets/sheet").Append(i + 1).Append(".xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>");
                wb.Append("<sheet name=\"").Append(Esc(noms[i])).Append("\" sheetId=\"").Append(i + 1).Append("\" r:id=\"rId").Append(i + 1).Append("\"/>");
                rl.Append("<Relationship Id=\"rId").Append(i + 1).Append("\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet").Append(i + 1).Append(".xml\"/>");
            }
            rl.Append("<Relationship Id=\"rId").Append(noms.Length + 1).Append("\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>");
            ct.Append("</Types>"); wb.Append("</sheets></workbook>");
            Ajouter(z, "[Content_Types].xml", ct.ToString());
            Ajouter(z, "_rels/.rels", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>");
            Ajouter(z, "xl/workbook.xml", wb.ToString());
            Ajouter(z, "xl/_rels/workbook.xml.rels", rl.ToString());
            Ajouter(z, "xl/styles.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"ddd dd/mm/yyyy\"/><numFmt numFmtId=\"165\" formatCode=\"+0.0%;-0.0%;0.0%\"/></numFmts><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFE3F1EF\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"5\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\" applyAlignment=\"1\"><alignment wrapText=\"1\" vertical=\"center\"/></xf><xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"3\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>");
            for (int i = 0; i < noms.Length; i++) Ajouter(z, "xl/worksheets/sheet" + (i + 1) + ".xml", Feuille(tsvs[i]));
        }
    }
}
