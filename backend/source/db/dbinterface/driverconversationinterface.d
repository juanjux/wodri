module db.dbinterface.driverconversationinterface;

import db.conversation: Conversation;
import std.typecons;

interface DriverConversationInterface
{
    import db.email: Email;
    Conversation get(in string id);

    Conversation getByReferences(in string userId,
                                 in string[] references,
                                 in Flag!"WithDeleted" withDeleted = No.WithDeleted);

    Conversation getByEmailId(in string emailId,
                              in Flag!"WithDeleted" withDeleted = No.WithDeleted);

    Conversation[] getByTag(in string tagName,
                            in string userId,
                            in uint limit=0,
                            in uint page=0,
                            in Flag!"WithDeleted" withDeleted = No.WithDeleted);

    void store(Conversation conv);

    void remove(in string id);

    /** Could create a new conversation **/
    Conversation addEmail(in Email email, in string[] tagsToAdd, in string[] tagsToRemove);

    /**
    Find any conversation with this email and update the links.[email].deleted field
    **/
    string setEmailDeleted(in string id, in bool setDel);

    bool isOwnedBy(in string convId, in string userName);
}
