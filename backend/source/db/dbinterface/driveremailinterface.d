module db.dbinterface.driveremailinterface;
import db.email: Email, EmailSummary;
import std.typecons;
import webbackend.apiemail;

static shared immutable HEADER_SEARCH_FIELDS = ["to", "subject", "cc", "bcc"];


interface DriverEmailInterface
{
    Email get(in string id);

    EmailSummary getSummary(in string dbId);

    string generateNewId();

    bool isOwnedBy(in string id, in string name);


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

    void setDeleted(in string dbId, in bool setDel);

    void removeById(in string dbId);

    void storeTextIndex(in Email email);

    string messageIdToDbId(in string messageId);

    string[] getReferencesFromPrevious(in string dbId);
}
