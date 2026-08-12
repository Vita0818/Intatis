import Foundation
import XCTest
import IntatisProtocol
@testable import IntatisTools

final class DocumentToolContractTests: XCTestCase {
    private let digestA = String(repeating: "a", count: 64)
    private let digestB = String(repeating: "b", count: 64)

    func testDocumentSchemasAreClosedAndDoNotExposeExecutionControls() throws {
        let schemas = [
            ReadPDFArguments.schema,
            DocumentTextReadArguments.schema,
            DocumentOCRArguments.schema,
            DocumentRenderArguments.schema,
            DocumentExportPDFArguments.schema,
            DocumentWriteArguments.schema,
        ]
        for schema in schemas {
            let object = try XCTUnwrap(object(schema))
            XCTAssertEqual(object["type"], .string("object"))
            XCTAssertEqual(object["additionalProperties"], .bool(false))

            let encoded = String(data: try JSONEncoder().encode(schema), encoding: .utf8) ?? ""
            for forbidden in [
                "backend", "binary", "command", "executable", "environment", "allow_network",
                "temp_dir",
            ] {
                XCTAssertFalse(encoded.contains("\"\(forbidden)\""), forbidden)
            }
        }
    }

    func testReadPDFKeepsExistingFieldNamesAndRejectsUnknownControls() throws {
        let value = try ReadPDFArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "path":"reports/source.pdf",
          "pages":"1-3,5",
          "maxCharacters":12000
        }
        """#))
        XCTAssertEqual(value.path, "reports/source.pdf")
        XCTAssertEqual(value.pages, "1-3,5")
        XCTAssertEqual(value.maxCharacters, 12_000)

        assertDocumentError(.unsupportedOperation) {
            _ = try ReadPDFArguments.decodeValidated(
                ToolArgs(raw: #"{"path":"source.pdf","backend":"anything"}"#))
        }
        assertDocumentError(.validationFailed) {
            _ = try ReadPDFArguments.decodeValidated(
                ToolArgs(raw: #"{"path":"source.docx"}"#))
        }
        assertDocumentError(.validationFailed) {
            _ = try ReadPDFArguments.decodeValidated(
                ToolArgs(raw: #"{"path":"source.pdf","pages":"3-1"}"#))
        }
    }

    func testFixedFormatReadersUseOnlyPathAndCharacterBudget() throws {
        let xlsx = try DocumentTextReadArguments.decodeValidated(
            ToolArgs(raw: #"{"path":"data/book.xlsx","maxCharacters":200000}"#),
            format: .xlsx)
        XCTAssertEqual(xlsx.path, "data/book.xlsx")
        XCTAssertEqual(xlsx.maxCharacters, 200_000)

        let html = try DocumentTextReadArguments.decodeValidated(
            ToolArgs(raw: #"{"path":"site/index.htm"}"#),
            format: .html)
        XCTAssertEqual(html.path, "site/index.htm")

        assertDocumentError(.validationFailed) {
            _ = try DocumentTextReadArguments.decodeValidated(
                ToolArgs(raw: #"{"path":"book.pptx"}"#),
                format: .xlsx)
        }
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentTextReadArguments.decodeValidated(
                ToolArgs(raw: #"{"path":"book.xlsx","backend":"auto"}"#),
                format: .xlsx)
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentTextReadArguments.decodeValidated(
                ToolArgs(raw: #"{"path":"book.xlsx","options":{}}"#),
                format: .xlsx)
        }
    }

    func testOCRRequiresPDFDigestAndExplicitAllowlistedTesseractSettings() throws {
        let valid = try DocumentOCRArguments.decodeValidated(ToolArgs(raw: """
        {
          "input_path":"scans/report.pdf",
          "expected_source_sha256":"\(digestA)",
          "pages":"1-10",
          "languages":["eng","chi_sim"],
          "psm":6,
          "max_characters":250000
        }
        """))
        XCTAssertEqual(valid.languages, ["eng", "chi_sim"])
        XCTAssertEqual(valid.pageSegmentationMode, 6)

        assertDocumentError(.validationFailed) {
            _ = try DocumentOCRArguments.decodeValidated(ToolArgs(raw: """
            {"input_path":"scan.pdf","expected_source_sha256":"\(digestA)",
             "languages":["eng","eng"],"psm":6}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentOCRArguments.decodeValidated(ToolArgs(raw: """
            {"input_path":"scan.pdf","expected_source_sha256":"\(digestA)",
             "languages":["eng"],"psm":2}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentOCRArguments.decodeValidated(ToolArgs(raw: """
            {"input_path":"scan.png","expected_source_sha256":"\(digestA)",
             "languages":["eng"],"psm":6}
            """))
        }
    }

    func testRenderFreezesVisualControlsBudgetsAndReplacementCAS() throws {
        let valid = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
        {
          "input_format":"pdf",
          "input_path":"reports/source.pdf",
          "expected_source_sha256":"\(digestA)",
          "output_dir":"reports/source-pages",
          "pages":"all",
          "dpi":200,
          "page_box":"media",
          "background":"transparent",
          "annotations":"hide",
          "maximum_page_pixels":40000000,
          "maximum_total_pixels":120000000,
          "maximum_output_bytes":268435456
        }
        """))
        XCTAssertEqual(valid.resolvedDPI, 200)
        XCTAssertEqual(valid.resolvedPageBox, .media)
        XCTAssertEqual(valid.resolvedBackground, .transparent)
        XCTAssertEqual(valid.resolvedAnnotations, .hide)

        assertDocumentError(.validationFailed) {
            _ = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"pdf","input_path":"a.pdf","expected_source_sha256":"\(digestA)",
             "output_dir":"pages","maximum_page_pixels":50000000,
             "maximum_total_pixels":40000000}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"pdf","input_path":"a.pdf","expected_source_sha256":"\(digestA)",
             "output_dir":"pages","replace_existing":true}
            """))
        }
        _ = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
        {"input_format":"pdf","input_path":"a.pdf","expected_source_sha256":"\(digestA)",
         "output_dir":"pages","replace_existing":true,"expected_output_sha256":"\(digestB)"}
        """))
    }

    func testHTMLRenderAndExportBindOnlyExplicitLocalAssets() throws {
        let render = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
        {"input_format":"html","input_path":"site/index.html",
         "expected_source_sha256":"\(digestA)","local_asset_paths":["site/app.css","site/logo.png"],
         "output_dir":"site/preview"}
        """))
        XCTAssertEqual(render.localAssetPaths, ["site/app.css", "site/logo.png"])

        let export = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
        {"input_format":"html","input_path":"site/index.html",
         "expected_source_sha256":"\(digestA)","local_asset_paths":["site/app.css"],
         "output_path":"site/index.pdf"}
        """))
        XCTAssertEqual(export.localAssetPaths, ["site/app.css"])

        assertDocumentError(.validationFailed) {
            _ = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"docx","input_path":"a.docx","expected_source_sha256":"\(digestA)",
             "local_asset_paths":["image.png"],"output_path":"a.pdf"}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"html","input_path":"a.html","expected_source_sha256":"\(digestA)",
             "local_asset_paths":["https://example.com/a.css"],"output_dir":"pages"}
            """))
        }
    }

    func testHTMLWriteBindsOnlyExplicitLocalAssets() throws {
        let write = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"html","mode":"create","output_path":"site/index.html",
          "local_asset_paths":["site/logo.png"],
          "operations":[
            {"kind":"xpath.append","parameters":{
              "xpath":"//body","expected_match_count":1,
              "html":"<img src=\"logo.png\" alt=\"logo\">"
            }}
          ]
        }
        """#))
        XCTAssertEqual(write.localAssetPaths, ["site/logo.png"])

        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"docx","mode":"create","output_path":"report.docx",
              "local_asset_paths":["assets/logo.png"],
              "operations":[{"kind":"paragraph.add","parameters":{"text":"Hello"}}]
            }
            """#))
        }
    }

    func testExportPDFRejectsPDFInputAndRequiresExactExtensions() throws {
        _ = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
        {"input_format":"docx","input_path":"reports/a.docx",
         "expected_source_sha256":"\(digestA)","output_path":"reports/a.pdf"}
        """))

        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"pdf","input_path":"a.pdf","expected_source_sha256":"\(digestA)",
             "output_path":"copy.pdf"}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"pptx","input_path":"a.docx","expected_source_sha256":"\(digestA)",
             "output_path":"a.pdf"}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"docx","input_path":"same.pdf","expected_source_sha256":"\(digestA)",
             "output_path":"same.pdf"}
            """))
        }

        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentExportPDFArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"epub","input_path":"book.epub",
             "expected_source_sha256":"\(digestA)","output_path":"book.pdf"}
            """))
        }
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"epub","input_path":"book.epub",
             "expected_source_sha256":"\(digestA)","output_dir":"book-pages"}
            """))
        }
    }

    func testWriteCreateEditAndInPlaceDigestInvariants() throws {
        let create = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"docx","mode":"create","output_path":"new.docx",
          "operations":[{"kind":"paragraph.add","parameters":{"text":"Hello"}}]
        }
        """#))
        XCTAssertEqual(create.mode, .create)

        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
            {"format":"docx","mode":"create","input_path":"old.docx",
             "expected_source_sha256":"\(digestA)","output_path":"new.docx",
             "operations":[{"kind":"paragraph.add","parameters":{"text":"Hello"}}]}
            """))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
            {"format":"docx","mode":"edit","input_path":"old.docx",
             "output_path":"new.docx",
             "operations":[{"kind":"paragraph.add","parameters":{"text":"Hello"}}]}
            """))
        }
        _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
        {"format":"docx","mode":"edit","input_path":"same.docx",
         "expected_source_sha256":"\(digestA)","output_path":"same.docx",
         "replace_existing":true,"expected_output_sha256":"\(digestA)",
         "operations":[{"kind":"paragraph.add","parameters":{"text":"Hello"}}]}
        """))
        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
            {"format":"docx","mode":"edit","input_path":"same.docx",
             "expected_source_sha256":"\(digestA)","output_path":"same.docx",
             "replace_existing":true,"expected_output_sha256":"\(digestB)",
             "operations":[{"kind":"paragraph.add","parameters":{"text":"Hello"}}]}
            """))
        }
    }

    func testWriteRejectsPDFMutationAndUnknownOperationEnvelopeKeys() throws {
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"pdf","mode":"edit","input_path":"a.pdf","output_path":"a.pdf",
              "operations":[{"kind":"page.delete","parameters":{"page":1}}]
            }
            """#))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"docx","mode":"create","output_path":"a.docx",
              "operations":[{"kind":"paragraph.add","parameters":{"text":"x"},"fallback":true}]
            }
            """#))
        }
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"docx","mode":"create","output_path":"a.docx",
              "operations":[{"kind":"paragraph.delete","parameters":{"paragraph_index":0}}]
            }
            """#))
        }
    }

    func testDOCXMatrixIsClosedAndSectionMutationMustChangeAProperty() throws {
        _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"docx","mode":"create","output_path":"a.docx",
          "operations":[
            {"kind":"run.add","parameters":{"paragraph_index":0,"text":"world","bold":true}},
            {"kind":"table.add","parameters":{"values":[["A","B"],["1","2"]]}},
            {"kind":"image.add","parameters":{"path":"assets/chart.png","width_points":300}},
            {"kind":"header.set_text","parameters":{"section_index":0,"text":"Header"}},
            {"kind":"footer.set_text","parameters":{"section_index":0,"text":"Footer"}},
            {"kind":"section.set","parameters":{"section_index":0,"orientation":"landscape"}}
          ]
        }
        """#))

        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"docx","mode":"create","output_path":"a.docx",
              "operations":[{"kind":"section.set","parameters":{"section_index":0}}]
            }
            """#))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"docx","mode":"create","output_path":"a.docx",
              "operations":[{"kind":"paragraph.add","parameters":{"text":"x","xml":"<w:p/>"}}]
            }
            """#))
        }
    }

    func testPPTXMatrixExcludesDeleteReorderCloneAndBoundsCharts() throws {
        _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"pptx","mode":"create","output_path":"deck.pptx",
          "operations":[
            {"kind":"slide.add","parameters":{"layout_index":0,"title":"Q1"}},
            {"kind":"shape.add","parameters":{"slide_index":0,"shape_type":"rectangle",
             "x_points":10,"y_points":10,"width_points":100,"height_points":50}},
            {"kind":"chart.add","parameters":{"slide_index":0,"chart_type":"column",
             "categories":["A","B"],"series_name":"Revenue","values":[1,2],
             "x_points":10,"y_points":80,"width_points":400,"height_points":240}}
          ]
        }
        """#))

        for kind in ["slide.delete", "slide.reorder", "slide.clone"] {
            assertDocumentError(.unsupportedOperation) {
                _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
                {"format":"pptx","mode":"create","output_path":"deck.pptx",
                 "operations":[{"kind":"\(kind)","parameters":{}}]}
                """))
            }
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"pptx","mode":"create","output_path":"deck.pptx",
              "operations":[{"kind":"chart.add","parameters":{"slide_index":0,
               "chart_type":"column","categories":["A","B"],"series_name":"Revenue",
               "values":[1],"x_points":10,"y_points":10,"width_points":100,"height_points":100}}]
            }
            """#))
        }
    }

    func testXLSXMatrixRejectsMacrosExternalConnectionsPivotAndRaggedRanges() throws {
        _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"xlsx","mode":"create","output_path":"book.xlsx",
          "operations":[
            {"kind":"sheet.add","parameters":{"name":"Summary"}},
            {"kind":"cell.set","parameters":{"sheet":"Summary","cell":"A1","value":"=SUM(B1:B3)"}},
            {"kind":"range.set","parameters":{"sheet":"Summary","start_cell":"B1","values":[[1,2],[3,4]]}},
            {"kind":"style.set","parameters":{"sheet":"Summary","range":"A1:B2","bold":true}},
            {"kind":"table.add","parameters":{"sheet":"Summary","range":"A1:B2","name":"SummaryTable"}},
            {"kind":"name.set","parameters":{"name":"Totals","reference":"Summary!$A$1:$A$2"}},
            {"kind":"chart.add","parameters":{"sheet":"Summary","chart_type":"line",
             "data_range":"B1:B2","category_range":"A1:A2","anchor":"D2"}}
          ]
        }
        """#))

        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"xlsx","mode":"create","output_path":"book.xlsm",
              "operations":[{"kind":"sheet.add","parameters":{"name":"S"}}]
            }
            """#))
        }
        assertDocumentError(.unsupportedFeature) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"xlsx","mode":"create","output_path":"book.xlsx",
              "operations":[{"kind":"cell.set","parameters":{"sheet":"S","cell":"A1",
               "value":"='[external.xlsx]Sheet1'!A1"}}]
            }
            """#))
        }
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"xlsx","mode":"create","output_path":"book.xlsx",
              "operations":[{"kind":"pivot.add","parameters":{}}]
            }
            """#))
        }
        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"xlsx","mode":"create","output_path":"book.xlsx",
              "operations":[{"kind":"range.set","parameters":{"sheet":"S","start_cell":"A1",
               "values":[[1,2],[3]]}}]
            }
            """#))
        }
    }

    func testHTMLMatrixRequiresExactMatchCountAndRejectsActiveRemoteContent() throws {
        _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"html","mode":"create","output_path":"index.html",
          "operations":[
            {"kind":"xpath.set_text","parameters":{"xpath":"//h1","expected_match_count":1,"text":"Title"}},
            {"kind":"xpath.set_attribute","parameters":{"xpath":"//img","expected_match_count":1,
             "name":"src","value":"assets/logo.png"}},
            {"kind":"xpath.append","parameters":{"xpath":"//main","expected_match_count":1,"html":"<p>Local</p>"}},
            {"kind":"xpath.remove","parameters":{"xpath":"//aside","expected_match_count":1}}
          ]
        }
        """#))

        assertDocumentError(.validationFailed) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"html","mode":"create","output_path":"index.html",
              "operations":[{"kind":"xpath.remove","parameters":{"xpath":"//aside"}}]
            }
            """#))
        }
        assertDocumentError(.unsupportedFeature) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"html","mode":"create","output_path":"index.html",
              "operations":[{"kind":"xpath.set_attribute","parameters":{"xpath":"//img",
               "expected_match_count":1,"name":"src","value":"https://example.com/a.png"}}]
            }
            """#))
        }
        assertDocumentError(.unsupportedFeature) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"html","mode":"create","output_path":"index.html",
              "operations":[{"kind":"xpath.append","parameters":{"xpath":"//main",
               "expected_match_count":1,"html":"<script>alert(1)</script>"}}]
            }
            """#))
        }
    }

    func testEPUBMatrixIsCandidateSubsetAndRejectsRemoteOrTraversalHrefs() throws {
        _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
        {
          "format":"epub","mode":"create","output_path":"book.epub",
          "operations":[
            {"kind":"metadata.set","parameters":{"field":"title","value":"Book"}},
            {"kind":"resource.add","parameters":{"id":"chapter1","source_path":"chapters/one.xhtml",
             "href":"text/one.xhtml","media_type":"application/xhtml+xml"}},
            {"kind":"spine.append","parameters":{"resource_id":"chapter1","linear":true}},
            {"kind":"toc.add","parameters":{"label":"One","href":"text/one.xhtml"}}
          ]
        }
        """#))

        for href in ["https://example.com/one.xhtml", "../one.xhtml", "/one.xhtml"] {
            assertAnyDocumentError {
                _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
                {"format":"epub","mode":"create","output_path":"book.epub",
                 "operations":[{"kind":"toc.add","parameters":{"label":"One","href":"\(href)"}}]}
                """))
            }
        }
        for kind in ["resource.remove", "spine.reorder", "toc.replace"] {
            assertDocumentError(.unsupportedOperation) {
                _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: """
                {"format":"epub","mode":"create","output_path":"book.epub",
                 "operations":[{"kind":"\(kind)","parameters":{}}]}
                """))
            }
        }
    }

    func testForbiddenExecutionControlsAreRejectedEvenWhenNested() throws {
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentWriteArguments.decodeValidated(ToolArgs(raw: #"""
            {
              "format":"docx","mode":"create","output_path":"a.docx",
              "operations":[{"kind":"paragraph.add","parameters":{"text":"x","env":{"A":"B"}}}]
            }
            """#))
        }
        assertDocumentError(.unsupportedOperation) {
            _ = try DocumentRenderArguments.decodeValidated(ToolArgs(raw: """
            {"input_format":"pdf","input_path":"a.pdf","expected_source_sha256":"\(digestA)",
             "output_dir":"pages","command":"pdftoppm"}
            """))
        }
    }

    private func object(_ value: JSONValue) -> [String: JSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    private func assertDocumentError(
        _ expected: DocumentToolErrorCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected DocumentToolError", file: file, line: line)
        } catch let error as DocumentToolError {
            XCTAssertEqual(error.code, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertAnyDocumentError(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("expected DocumentToolError", file: file, line: line)
        } catch is DocumentToolError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
