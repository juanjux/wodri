module db.searchresult;

struct SearchResult
{
    import db.conversation;
    const Conversation conversation;
    ulong[] matchingEmailsIdx;
}
