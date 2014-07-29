module db.userfilter;

import std.string;
import std.algorithm;
import vibe.core.log;
import vibe.data.bson;
import vibe.db.mongo.mongo;
import db.mongo;
import db.config;
import db.email;
version(unittest)import std.stdio;


enum SizeRuleType
{
    GreaterThan,
    SmallerThan,
    None
}


struct Match
{
    bool withAttachment = false;
    bool withHtml       = false;
    string[string]   headerMatches;
    string[]         bodyMatches;
    SizeRuleType     totalSizeType = SizeRuleType.None;
    ulong            totalSizeValue;
}


struct Action
{
    bool noInbox      = false;
    bool markAsRead   = false;
    bool deleteIt     = false;
    bool neverSpam    = false;
    bool setSpam      = false;
    string[] addTags;
    string[] forwardTo;
}


final class UserFilter
{
    package
    {
        Match match;
        Action action;
    }

    this(Match match, Action action)
    {
        this.match  = match;
        this.action = action;
    }


    void apply(Email email, ref bool[string] convTags) const
    {
        if (checkMatch(email)) 
            applyAction(email, convTags);
    }


    private bool checkMatch(Email email) const
    {
        if (this.match.withAttachment && !email.attachments.length)
            return false;

        if (this.match.withHtml)
        {
            bool hasHtml = false;
            foreach(subpart; email.textParts)
                if (subpart.ctype == "text/html")
                    hasHtml = true;
            if (!hasHtml)
                return false;
        }

        foreach(matchHeaderName, matchHeaderFilter; this.match.headerMatches)
            if (countUntil(email.getHeader(matchHeaderName).rawValue,
                           matchHeaderFilter) == -1)
                return false;

        foreach(part; email.textParts)
        {
            foreach(string bodyMatch; this.match.bodyMatches)
                if (countUntil(part.content, bodyMatch) == -1)
                    return false;
        }

        if (this.match.totalSizeType != SizeRuleType.None)
        {
            auto emailSize = email.size();
            if (this.match.totalSizeType == SizeRuleType.GreaterThan &&
                emailSize < this.match.totalSizeValue)
            {
                return false;
            }
            else if (this.match.totalSizeType == SizeRuleType.SmallerThan &&
                emailSize > this.match.totalSizeValue)
            {
                return false;
            }
        }
        return true;
    }


    private void applyAction(Email email, ref bool[string] convTags) const
    {
        // email.tags == false actually mean to the rest of the retriever processes: "it
        // doesnt have the tag and please dont add it after this point"
        if (this.action.noInbox)
            convTags["inbox"] = false;

        if (this.action.markAsRead) 
            convTags["unread"] = false;

        if (this.action.deleteIt)
            convTags["deleted"] = true;

        if (this.action.neverSpam)
            convTags["spam"] = false;

        if (this.action.setSpam)
            convTags["spam"] = true;

        foreach(string tag; this.action.addTags)
        {
            tag = toLower(tag);
            if (tag !in convTags)
                convTags[tag] = true;
        }

        if (this.action.forwardTo.length)
            email.forwardedTo ~= this.action.forwardTo;
    }


    // ===================================================================
    // DB methods, puts these under a version() if other DBs are supported
    // ===================================================================

    static const(UserFilter[]) getByAddress(string address)
    {
        UserFilter[] res;
        auto userRuleFindJson = parseJsonString(
                format(`{"destinationAccounts": {"$in": ["%s"]}}`, address)
                );
        auto userRuleCursor   = collection("userrule").find(userRuleFindJson);

        foreach(ref rule; userRuleCursor)
        {
            Match match;
            Action action;
            try
            {
                auto sizeRule = bsonStr(rule.match_sizeRuleType);
                switch(sizeRule)
                {
                    case "None":
                        match.totalSizeType = SizeRuleType.None; break;
                    case "SmallerThan":
                        match.totalSizeType = SizeRuleType.SmallerThan; break;
                    case "GreaterThan":
                        match.totalSizeType = SizeRuleType.GreaterThan; break;
                    default:
                        auto err = "SizeRuleType must be one of None, GreaterThan or SmallerThan";
                        logError(err);
                        throw new Exception(err);
                }

                match.withAttachment = bsonBool    (rule.match_withAttachment);
                match.withHtml       = bsonBool    (rule.match_withHtml);
                match.totalSizeValue = to!ulong    (bsonNumber(rule.match_totalSizeValue));
                match.bodyMatches    = bsonStrArray(rule.match_bodyText);
                match.headerMatches  = bsonStrHash (rule.match_headers);

                action.noInbox       = bsonBool    (rule.action_noInbox);
                action.markAsRead    = bsonBool    (rule.action_markAsRead);
                action.deleteIt      = bsonBool    (rule.action_delete);
                action.neverSpam     = bsonBool    (rule.action_neverSpam);
                action.setSpam       = bsonBool    (rule.action_setSpam);
                action.forwardTo     = bsonStrArray(rule.action_forwardTo);
                action.addTags       = bsonStrArray(rule.action_addTags);

                res ~= new UserFilter(match, action);
            } catch (Exception e)
            logWarn("Error deserializing rule from DB, ignoring: %s: %s", rule, e);
        }
        return res;
    }
}


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|



version(db_test)
version(db_usetestdb)
{

    import db.test_support;

    unittest
    {
        import std.stdio;
        import std.path;
        import retriever.incomingemail;
        import db.email;

        recreateTestDb();

        writeln("Testing UserFilter matching");
        auto config = getConfig();
        auto testDir = buildPath(config.mainDir, "backend", "test");
        auto testEmailDir = buildPath(testDir, "testemails");
        bool[string] tags;

        // this will change the outer "tags" hash
        Email reInstance(Match match, Action action)
        {
            auto inEmail = new IncomingEmailImpl();
            inEmail.loadFromFile(buildPath(testEmailDir, "with_2megs_attachment"),
                                 buildPath(testDir, "attachments"));
            auto dbEmail  = new Email(inEmail);
            dbEmail.destinationAddress = "foo@foo.com";
            dbEmail.userId = "fakeuserid";
            // a little kludge so I dont have to store this email to get an id
            dbEmail.dbId = Email.messageIdToDbId(dbEmail.messageId);
            auto filter   = new UserFilter(match, action);
            tags = ["inbox": true];
            filter.apply(dbEmail, tags);
            return dbEmail;
        }

        // Match the From, set unread to false
        Match match; match.headerMatches["from"] = "someuser@somedomain.com";
        Action action; action.markAsRead = true;
        reInstance(match, action);
        assert("unread" in tags && !tags["unread"]);

        // Fail to match the From
        Match match2; match2.headerMatches["from"] = "foo@foo.com";
        Action action2; action2.markAsRead = true;
        reInstance(match2, action2);
        assert("unread" !in tags);

        // Match the withAttachment, set inbox to false
        Match match3; match3.withAttachment = true;
        Action action3; action3.noInbox = true;
        reInstance(match3, action3);
        assert("inbox" in tags && !tags["inbox"]);

        // Match the withHtml, set deleted to true
        Match match4; match4.withHtml = true;
        Action action4; action4.deleteIt = true;
        reInstance(match4, action4);
        assert("deleted" in tags && tags["deleted"]);

        // Negative match on body
        Match match5; match5.bodyMatches = ["nomatch_atall"];
        Action action5; action5.deleteIt = true;
        reInstance(match5, action5);
        assert("deleted" !in tags);

        //Match SizeGreaterThan, set tag
        Match match6;
        match6.totalSizeType = SizeRuleType.GreaterThan;
        match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
        Action action6; action6.addTags = ["testtag1", "testtag2"];
        auto email1 = reInstance(match6, action6);
        assert("testtag1" in tags && "testtag2" in tags);

        //Dont match SizeGreaterThan, set tag
        auto size1 = email1.size();
        auto size2 = 2*1024*1024;
        Match match7;
        match7.totalSizeType = SizeRuleType.GreaterThan;
        match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
        Action action7; action7.addTags = ["testtag1", "testtag2"];
        auto email2 = reInstance(match7, action7);
        assert("testtag1" !in tags && "testtag2" !in tags);

        // Match SizeSmallerThan, set forward
        Match match8;
        match8.totalSizeType = SizeRuleType.SmallerThan;
        match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
        Action action8;
        action8.forwardTo = ["juanjux@yahoo.es"];
        auto email3 = reInstance(match8, action8);
        assert(email3.forwardedTo[0] == "juanjux@yahoo.es");

        // Dont match SizeSmallerTham
        Match match9;
        match9.totalSizeType = SizeRuleType.SmallerThan;
        match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
        Action action9;
        action9.forwardTo = ["juanjux@yahoo.es"];
        auto email4 = reInstance(match9, action9);
        assert(!email4.forwardedTo.length);
    }

    unittest // getByAddress
    {
        writeln("Testing UserFilter.getByAddress");
        auto filters = UserFilter.getByAddress("testuser@testdatabase.com");
        assert(filters.length == 1);
        assert(!filters[0].match.withAttachment);
        assert(!filters[0].match.withHtml);
        assert(filters[0].match.totalSizeType        == SizeRuleType.GreaterThan);
        assert(filters[0].match.totalSizeValue       == 100485760);
        assert(filters[0].match.bodyMatches.length   == 1);
        assert(filters[0].match.bodyMatches[0]       == "XXXBODYMATCHXXX");
        assert(filters[0].match.headerMatches.length == 1);
        assert("From" in filters[0].match.headerMatches);
        assert(filters[0].match.headerMatches["From"] == "juanjo@juanjoalvarez.net");
        assert(!filters[0].action.forwardTo.length);
        assert(!filters[0].action.noInbox);
        assert(filters[0].action.markAsRead);
        assert(!filters[0].action.deleteIt);
        assert(filters[0].action.neverSpam);
        assert(!filters[0].action.setSpam);
        assert(filters[0].action.addTags == ["testtag1", "testtag2"]);
        auto filters2 = UserFilter.getByAddress("anotherUser@anotherdomain.com");
        assert(filters2[0].action.addTags == ["testtag3", "testtag4"]);
        auto newfilters = UserFilter.getByAddress("anotherUser@testdatabase.com");
        assert(filters2[0].action.addTags == newfilters[0].action.addTags);
    }
}
