module db.emaildbinterface;
import db.email: Email, EmailSummary;
import webbackend.apiemail;
import std.typecons;

static shared immutable HEADER_SEARCH_FIELDS = ["to", "subject", "cc", "bcc"];

struct EmailAndConvIds
{
    string emailId;
    string convId;
}

interface EmailDbInterface
{
    Email get(in string id);

    EmailSummary getSummary(in string dbId);

    string generateNewId();

    bool isOwnedBy(in string id, in string name);

    const(EmailAndConvIds[]) searchEmails(
            in string[] needles,
            in string userId,
            in string dateStart = "",
            in string dateEnd = ""
    );

    string store(
            Email email,
            in Flag!"ForceInsertNew" forceInsertNew = No.ForceInsertNew,
            in Flag!"StoreAttachMents" storeAttachMents = Yes.StoreAttachMents
    );

    string addAttachment(
            in string emailDbId,
            in ApiAttachment apiAttach,
            in string base64Content
    );

    void deleteAttachment(
            in string emailDbId,
            in string attachmentId
    );

    string getOriginal(in string dbId);

    void setDeleted(
            in string dbId,
            in bool setDel,
            in Flag!"UpdateConversation" updateConv = Yes.UpdateConversation
    );

    void removeById(
            in string dbId,
            in Flag!"UpdateConversation" updateConv = Yes.UpdateConversation
    );

    void storeTextIndex(in Email email);

    string messageIdToDbId(in string messageId);

    string[] getReferencesFromPrevious(in string dbId);
}
