module retriever.userrule;

import std.string;
import retriever.incomingemail;

version(unittest)
{
    import retriever.config;
    import std.path;
    import std.stdio;
    import std.algorithm;
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
    string[] tagsToAdd;
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

    
    void apply(IncomingEmail email)
    {
        if (checkMatch(email))
            applyAction(email);
    }

    bool checkMatch(IncomingEmail email)
    {   
        if (this.match.withAttachment && !email.attachments.length)
            return false;

        if (this.match.withHtml)
        {
            bool hasHtml = false;
            foreach(MIMEPart subpart; email.textualParts)
                if (subpart.ctype.name == "text/html")
                    hasHtml = true;
            if (!hasHtml)
                return false;
        }
        
        foreach(string matchHeaderName, string matchHeaderFilter; this.match.headerMatches)
        {
            string emailHeaderContent = email.headers.get(matchHeaderName, "");
            if (!emailHeaderContent.length || 
                indexOf(emailHeaderContent, this.match.headerMatches[matchHeaderName]) == -1)
                return false;
        }

        foreach(MIMEPart part; email.textualParts)
            foreach(string bodyMatch; this.match.bodyMatches)
                if (indexOf(part.textContent, bodyMatch) == -1)
                    return false;
            
        if (this.match.withSizeLimit)
        {
            auto mailSize = email.computeSize();
            if (this.match.totalSizeType == SizeRuleType.GreaterThan &&
                mailSize < this.match.totalSizeValue)
                return false;
            else if (this.match.totalSizeType == SizeRuleType.SmallerThan &&
                mailSize > this.match.totalSizeValue)
                return false;
        }
        return true;
    }

    
    void applyAction(IncomingEmail email)
    {
        // email.tags == false actually mean to the rest of the retriever 
        // processes: "it doesnt have the tag and please dont add it after this point"
        if (this.action.noInbox)
            email.tags["inbox"] = false;

        if (this.action.markAsRead)
            email.tags["unread"] = false;

        if (this.action.deleteIt)
            email.tags["deleted"] = true;

        if (this.action.neverSpam)
            email.tags["spam"] = false;

        if (this.action.setSpam)
            email.tags["spam"] = true;

        if (this.action.tagFavorite)
            email.tags["favorite"] = true;

        foreach(string tag; this.action.tagsToAdd)
        {
            tag = toLower(tag);
            if (tag !in email.tags)
                email.tags[tag] = true;
        }

        if (this.action.forwardTo.length)
            email.doForwardTo ~= this.action.forwardTo;
    }
}


// XXX cargar de MongoDB
UserFilter[] getUserFilters(string user)
{
    return [];
}


version(UserRuleTest)
{
    unittest
    {
        auto config = getConfig();
        auto testDir = buildPath(config.mainDir, "backend", "test");
        auto testMailDir = buildPath(testDir, "testmails");

        IncomingEmail reInstance(Match match, Action action)
        {   
            auto email = new IncomingEmail(buildPath(testDir, "rawmails"), 
                                           buildPath(testDir, "attachments"));
            email.loadFromFile(buildPath(testMailDir, "with_attachment"));
            auto filter = new UserFilter(match, action);
            filter.apply(email);
            return email;
        }

        // Match the From, set unread to false
        Match match; match.headerMatches["From"] = "juanjo@juanjoalvarez.net";
        Action action; action.markAsRead = true;
        auto email = reInstance(match, action);
        assert("unread" in email.tags && !email.tags["unread"]);

        // Fail to match the From
        Match match2; match2.headerMatches["From"] = "foo@foo.com";
        Action action2; action2.markAsRead = true;
        email = reInstance(match2, action2);
        assert("unread" !in email.tags);

        // Match the withAttachment, set inbox to false
        Match match3; match3.withAttachment = true;
        Action action3; action3.noInbox = true;
        email = reInstance(match3, action3);
        assert("inbox" in email.tags && !email.tags["inbox"]);

        // Match the withHtml, set deleted to true
        Match match4; match4.withHtml = true;
        Action action4; action4.deleteIt = true;
        email = reInstance(match4, action4);
        assert("deleted" in email.tags && email.tags["deleted"]);

        // Negative match on body
        Match match5; match5.bodyMatches = ["nomatch_atall"];
        Action action5; action5.deleteIt = true;
        email = reInstance(match5, action5);
        assert("deleted" !in email.tags);

        //Match SizeGreaterThan, set tags
        Match match6; 
        match6.totalSizeValue = 1024*1024; // 1MB, the email is 1.36MB
        match6.withSizeLimit = true;
        Action action6; action6.tagsToAdd = ["testtag1", "testtag2"];
        email = reInstance(match6, action6);
        assert("testtag1" in email.tags && "testtag2" in email.tags);

        //Dont match SizeGreaterThan, set tags
        auto size1 = email.computeSize();
        auto size2 = 2*1024*1024;
        Match match7; 
        match7.totalSizeValue = 2*1024*1024; // 1MB, the email is 1.36MB
        match7.withSizeLimit = true;
        Action action7; action7.tagsToAdd = ["testtag1", "testtag2"];
        email = reInstance(match7, action7);
        assert("testtag1" !in email.tags && "testtag2" !in email.tags);

        // Match SizeSmallerThan, set forward
        Match match8; 
        match8.totalSizeType = SizeRuleType.SmallerThan;
        match8.totalSizeValue = 2*1024*1024; // 2MB, the email is 1.38MB
        match8.withSizeLimit = true;
        Action action8;
        action8.forwardTo = "juanjux@yahoo.es";
        email = reInstance(match8, action8);
        assert(email.doForwardTo[0] == "juanjux@yahoo.es");

        // Dont match SizeSmallerTham
        Match match9; 
        match9.totalSizeType = SizeRuleType.SmallerThan;
        match9.totalSizeValue = 1024*1024; // 2MB, the email is 1.39MB
        match9.withSizeLimit = true;
        Action action9;
        action9.forwardTo = "juanjux@yahoo.es";
        email = reInstance(match9, action9);
        assert(!email.doForwardTo.length);
        
    }
}
