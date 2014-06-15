module retriever.userrule;

import std.string;
import vibe.core.log;
import vibe.data.bson;
import retriever.incomingemail;
import retriever.db: getAddressFilters;
import retriever.recipientemail;


version(unittest)
{
    import std.path;
    import std.stdio;
    import std.algorithm;
    import retriever.db: getConfig;
}


enum SizeRuleType
{
    GreaterThan,
    SmallerThan
}


struct Match
{
    bool withAttachment = false;
    bool withHtml       = false;
    bool withSizeLimit  = false;
    string[string]   headerMatches;
    string[]         bodyMatches;
    SizeRuleType     totalSizeType = SizeRuleType.GreaterThan;
    ulong            totalSizeValue;
}


struct Action
{
    bool noInbox      = false;
    bool markAsRead   = false;
    bool deleteIt     = false;
    bool neverSpam    = false;
    bool setSpam      = false;
    bool tagFavorite  = false;
    string[] addTags;
    string forwardTo;
}


class UserFilter
{
    Match match;
    Action action;

    this(ref Match match, ref Action action)
    {
        this.match  = match;
        this.action = action;
    }


    void apply(ref RecipientEmail recipientEmail)
    {
        if (checkMatch(recipientEmail))
            applyAction(recipientEmail);
    }

    bool checkMatch(ref RecipientEmail recipientEmail)
    {
        if (this.match.withAttachment && !recipientEmail.email.attachments.length)
            return false;

        if (this.match.withHtml)
        {
            bool hasHtml = false;
            foreach(MIMEPart subpart; recipientEmail.email.textualParts)
                if (subpart.ctype.name == "text/html")
                    hasHtml = true;
            if (!hasHtml)
                return false;
        }

        foreach(string matchHeaderName, string matchHeaderFilter; this.match.headerMatches)
        {
            if (matchHeaderName !in recipientEmail.email.headers ||
                indexOf(recipientEmail.email.headers[matchHeaderName].rawValue, this.match.headerMatches[matchHeaderName]) == -1)
                return false;
        }

        foreach(MIMEPart part; recipientEmail.email.textualParts)
        {
            foreach(string bodyMatch; this.match.bodyMatches)
                if (indexOf(part.textContent, bodyMatch) == -1)
                    return false;
        }

        if (this.match.withSizeLimit)
        {
            auto mailSize = recipientEmail.email.computeSize();
            if (this.match.totalSizeType == SizeRuleType.GreaterThan &&
                mailSize < this.match.totalSizeValue)
                return false;
            else if (this.match.totalSizeType == SizeRuleType.SmallerThan &&
                mailSize > this.match.totalSizeValue)
                return false;
        }
        return true;
    }


    void applyAction(ref RecipientEmail recipientEmail)
    {
        // email.tags == false actually mean to the rest of the retriever
        // processes: "it doesnt have the tag and please dont add it after this point"
        if (this.action.noInbox)
            recipientEmail.tags["inbox"] = false;

        if (this.action.markAsRead)
            recipientEmail.tags["unread"] = false;

        if (this.action.deleteIt)
            recipientEmail.tags["deleted"] = true;

        if (this.action.neverSpam)
            recipientEmail.tags["spam"] = false;

        if (this.action.setSpam)
            recipientEmail.tags["spam"] = true;

        if (this.action.tagFavorite)
            recipientEmail.tags["favorite"] = true;

        foreach(string tag; this.action.addTags)
        {
            tag = toLower(tag);
            if (tag !in recipientEmail.tags)
                recipientEmail.tags[tag] = true;
        }

        if (this.action.forwardTo.length)
            recipientEmail.doForwardTo ~= this.action.forwardTo;
    }
}


version(UserRuleTest)
unittest
{
    writeln("Starting userrule.d unittests...");
    auto filters = getAddressFilters("juanjux@juanjux.mooo.com");
    auto config = getConfig();
    auto testDir = buildPath(config.mainDir, "backend", "test");
    auto testMailDir = buildPath(testDir, "testmails");

    RecipientEmail reInstance(Match match, Action action)
    {
        auto email = new IncomingEmail(buildPath(testDir, "rawmails"),
                                       buildPath(testDir, "attachments"));
        email.loadFromFile(buildPath(testMailDir, "with_attachment"));

        auto recipientEmail = RecipientEmail(email, "foo@foo.com");
        recipientEmail.tags = ["inbox": true];

        auto filter = new UserFilter(match, action);
        filter.apply(recipientEmail);

        return recipientEmail;
    }

    // Match the From, set unread to false
    Match match; match.headerMatches["From"] = "juanjo@juanjoalvarez.net";
    Action action; action.markAsRead = true;
    auto recipientEmail = reInstance(match, action);
    assert("unread" in recipientEmail.tags && !recipientEmail.tags["unread"]);

    // Fail to match the From
    Match match2; match2.headerMatches["From"] = "foo@foo.com";
    Action action2; action2.markAsRead = true;
    recipientEmail = reInstance(match2, action2);
    assert("unread" !in recipientEmail.tags);

    // Match the withAttachment, set inbox to false
    Match match3; match3.withAttachment = true;
    Action action3; action3.noInbox = true;
    recipientEmail = reInstance(match3, action3);
    assert("inbox" in recipientEmail.tags && !recipientEmail.tags["inbox"]);

    // Match the withHtml, set deleted to true
    Match match4; match4.withHtml = true;
    Action action4; action4.deleteIt = true;
    recipientEmail = reInstance(match4, action4);
    assert("deleted" in recipientEmail.tags && recipientEmail.tags["deleted"]);

    // Negative match on body
    Match match5; match5.bodyMatches = ["nomatch_atall"];
    Action action5; action5.deleteIt = true;
    recipientEmail = reInstance(match5, action5);
    assert("deleted" !in recipientEmail.tags);

    //Match SizeGreaterThan, set tag
    Match match6;
    match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
    match6.withSizeLimit = true;
    Action action6; action6.addTags = ["testtag1", "testtag2"];
    recipientEmail = reInstance(match6, action6);
    assert("testtag1" in recipientEmail.tags && "testtag2" in recipientEmail.tags);

    //Dont match SizeGreaterThan, set tag
    auto size1 = recipientEmail.email.computeSize();
    auto size2 = 2*1024*1024;
    Match match7;
    match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
    match7.withSizeLimit = true;
    Action action7; action7.addTags = ["testtag1", "testtag2"];
    recipientEmail = reInstance(match7, action7);
    assert("testtag1" !in recipientEmail.tags && "testtag2" !in recipientEmail.tags);

    // Match SizeSmallerThan, set forward
    Match match8;
    match8.totalSizeType = SizeRuleType.SmallerThan;
    match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
    match8.withSizeLimit = true;
    Action action8;
    action8.forwardTo = "juanjux@yahoo.es";
    recipientEmail = reInstance(match8, action8);
    assert(recipientEmail.doForwardTo[0] == "juanjux@yahoo.es");

    // Dont match SizeSmallerTham
    Match match9;
    match9.totalSizeType = SizeRuleType.SmallerThan;
    match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
    match9.withSizeLimit = true;
    Action action9;
    action9.forwardTo = "juanjux@yahoo.es";
    recipientEmail = reInstance(match9, action9);
    assert(!recipientEmail.doForwardTo.length);

}
