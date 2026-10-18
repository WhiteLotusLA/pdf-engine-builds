// qpdf smoke test for the static, native-crypto QPDF.xcframework.
//
// Usage: smoke <writable-directory>
// Checks, in order: native crypto is the only provider; an AES-256 (R6) encrypted file
// round-trips; a wrong password is rejected; /PageLabels written by hand reads back through
// QPDFPageLabelDocumentHelper; the final file passes the same structural check as `qpdf --check`.
// Prints one "ok:" or "FAIL:" line per check and "qpdf smoke: all passed" at the end.
// Exit codes: 0 all passed, 1 a check failed, 2 usage.
#include <qpdf/Buffer.hh>
#include <qpdf/Constants.h>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFCryptoProvider.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFJob.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageLabelDocumentHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/QPDFXRefEntry.hh>

#include <cstdio>
#include <exception>
#include <memory>
#include <set>
#include <string>

namespace {

int failures = 0;

void check(bool condition, std::string const& label)
{
    if (condition) {
        std::printf("ok:   %s\n", label.c_str());
    } else {
        std::printf("FAIL: %s\n", label.c_str());
        ++failures;
    }
}

// A three-page document; page n draws the text "page n".
void build_three_pages(QPDF& pdf)
{
    pdf.emptyPDF();
    auto font = pdf.makeIndirectObject(QPDFObjectHandle::parse(
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"));
    for (int n = 1; n <= 3; ++n) {
        auto contents = pdf.newStream("BT /F1 12 Tf 72 720 Td (page " + std::to_string(n) + ") Tj ET\n");
        auto resources = QPDFObjectHandle::newDictionary();
        auto fonts = QPDFObjectHandle::newDictionary();
        fonts.replaceKey("/F1", font);
        resources.replaceKey("/Font", fonts);
        auto page = QPDFObjectHandle::newDictionary();
        page.replaceKey("/Type", QPDFObjectHandle::newName("/Page"));
        page.replaceKey("/MediaBox", QPDFObjectHandle::parse("[0 0 612 792]"));
        page.replaceKey("/Resources", resources);
        page.replaceKey("/Contents", contents);
        pdf.addPage(pdf.makeIndirectObject(page), false);
    }
}

} // namespace

int main(int argc, char** argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: smoke <writable-directory>\n");
        return 2;
    }
    std::string const dir = argv[1];
    std::string const final_path = dir + "/qpdf-smoke-final.pdf";

    try {
        // 1. Only the native crypto provider exists in this build.
        auto impls = QPDFCryptoProvider::getRegisteredImpls();
        check(impls == std::set<std::string>{"native"}, "native is the only registered crypto provider");
        check(QPDFCryptoProvider::getDefaultProvider() == "native", "the default crypto provider is native");

        // 2. AES-256 (R6) encrypt to memory.
        QPDF source;
        build_three_pages(source);
        QPDFWriter encrypting(source);
        encrypting.setOutputMemory();
        encrypting.setR6EncryptionParameters(
            "user-pw", "owner-pw", true, true, true, true, true, true, qpdf_r3p_full, true);
        encrypting.write();
        std::shared_ptr<Buffer> encrypted = encrypting.getBufferSharedPointer();
        check(encrypted && encrypted->getSize() > 0, "encrypted output is not empty");

        // 3. Decrypt with the user password and read the content back.
        QPDF reader;
        reader.setSuppressWarnings(true);
        reader.processMemoryFile("smoke-encrypted", reinterpret_cast<char const*>(encrypted->getBuffer()),
                                 encrypted->getSize(), "user-pw");
        int r = 0;
        int p = 0;
        int v = 0;
        QPDF::encryption_method_e stream_method = QPDF::e_none;
        QPDF::encryption_method_e string_method = QPDF::e_none;
        QPDF::encryption_method_e file_method = QPDF::e_none;
        bool encrypted_flag = reader.isEncrypted(r, p, v, stream_method, string_method, file_method);
        check(encrypted_flag && r == 6 && v == 5, "file is encrypted with revision 6, version 5");
        check(stream_method == QPDF::e_aesv3 && string_method == QPDF::e_aesv3, "streams and strings use AES-256");
        auto pages = reader.getAllPages();
        check(pages.size() == 3, "decrypted file has three pages");
        std::string first_page_text;
        if (!pages.empty()) {
            auto data = pages[0].getKey("/Contents").getStreamData(qpdf_dl_generalized);
            first_page_text.assign(reinterpret_cast<char const*>(data->getBuffer()), data->getSize());
        }
        check(first_page_text.find("(page 1) Tj") != std::string::npos, "page 1 content decrypts to the original text");

        // 4. A wrong password and a missing password are both refused with the password error.
        bool wrong_refused = false;
        try {
            QPDF bad;
            bad.setSuppressWarnings(true);
            bad.processMemoryFile("smoke-encrypted", reinterpret_cast<char const*>(encrypted->getBuffer()),
                                  encrypted->getSize(), "not-the-password");
        } catch (QPDFExc const& e) {
            wrong_refused = (e.getErrorCode() == qpdf_e_password);
        }
        check(wrong_refused, "a wrong password is refused with the password error");
        bool missing_refused = false;
        try {
            QPDF bad;
            bad.setSuppressWarnings(true);
            bad.processMemoryFile("smoke-encrypted", reinterpret_cast<char const*>(encrypted->getBuffer()),
                                  encrypted->getSize());
        } catch (QPDFExc const& e) {
            missing_refused = (e.getErrorCode() == qpdf_e_password);
        }
        check(missing_refused, "a missing password is refused with the password error");

        // 5. Write /PageLabels (pages 1-2 lowercase roman, page 3 decimal restarting at 1), save unencrypted.
        QPDF labelled;
        build_three_pages(labelled);
        labelled.getRoot().replaceKey(
            "/PageLabels", QPDFObjectHandle::parse("<< /Nums [ 0 << /S /r >> 2 << /S /D /St 1 >> ] >>"));
        QPDFWriter plain(labelled, final_path.c_str());
        plain.setObjectStreamMode(qpdf_o_generate);
        plain.setDeterministicID(true);
        plain.write();

        // 6. Reopen the saved file and read the labels back through the helper.
        QPDF relabelled;
        relabelled.setSuppressWarnings(true);
        relabelled.processFile(final_path.c_str());
        QPDFPageLabelDocumentHelper labels(relabelled);
        check(labels.hasPageLabels(), "the saved file has /PageLabels");
        auto first = labels.getLabelForPage(0);
        auto third = labels.getLabelForPage(2);
        check(first.isDictionary() && first.getKey("/S").isName() && first.getKey("/S").getName() == "/r",
              "page index 0 carries the lowercase roman label style");
        check(third.isDictionary() && third.getKey("/S").isName() && third.getKey("/S").getName() == "/D" &&
                  third.getKey("/St").isInteger() && third.getKey("/St").getIntValue() == 1,
              "page index 2 restarts decimal numbering at 1");
        check(relabelled.getWarnings().empty(), "reopening the saved file produced no warnings");
        // Object streams were requested: at least one xref entry must be type 2 (compressed).
        bool has_compressed = false;
        for (auto const& entry : relabelled.getXRefTable()) {
            if (entry.second.getType() == 2) {
                has_compressed = true;
                break;
            }
        }
        check(has_compressed, "the saved file stores objects in an object stream (xref type 2 entry)");

        // 7. The same structural check as `qpdf --check`.
        char const* const job_args[] = {"qpdf", "--check", final_path.c_str(), nullptr};
        QPDFJob job;
        job.initializeFromArgv(job_args);
        job.run();
        check(job.getExitCode() == 0 && !job.hasWarnings(), "qpdf --check finds no errors or warnings");
    } catch (std::exception const& e) {
        std::printf("FAIL: unexpected exception: %s\n", e.what());
        ++failures;
    }

    if (failures != 0) {
        std::printf("qpdf smoke: %d failure(s)\n", failures);
        return 1;
    }
    std::printf("qpdf smoke: all passed\n");
    return 0;
}
