import incomingemail;
import std.string;

// TODO
// Tipo para excepciones

enum SizeRuleType 
{
    GreaterThan,
    SmallerThan
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

class UserFilter
{
    Match match;
    Action action;

    this(ref Match match, ref Action action)
    {
        this.match  = match;
        this.action = action;
    }

    
    // XXX allow for regular expressions
    void apply(IncomingEmail email)
    {
        if (isEmailMatch(email))
            applyAction(email);
    }

    bool isEmailMatch(IncomingEmail email)
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

        // XXX email.setTag(forced=true);
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


// XXX cargar de MongoDB, dejar esta para tests
UserFilter[] getUserFilters(string user)
{
    Match match1;
    match1.headerMatches["From"]    = "juanjux@gmail.com";
    match1.headerMatches["Subject"] = "polompos";
    match1.withHtml                 = true;
    match1.bodyMatches             ~= "Texto flag";

    Action action1;
    action1.markAsRead = true;
    action1.noInbox = true;

    Action action2;
    action2.tagFavorite = true;
    action2.tagsToAdd ~= "testlabel";
    action2.forwardTo = "juanjux@yahoo.es";

    Match match2            = match1;
    match2.totalSizeType            = SizeRuleType.GreaterThan;
    match2.totalSizeValue           = 1024;

    auto filter1 = new UserFilter(match1, action1);
    auto filter2 = new UserFilter(match2, action2);

    return [filter1, filter2];
}

// XXX implementar y usar
//UserFilter[] getUserFiltersFromDB(string user)
//{
//}

unittest
{
    // XXX implementar:
    // 1. Elegir algunos mails fijos, alguno con adjuntos y cambiar el contenido
    // 2. Crear las reglas
    // 3. Aplicar el match, comprobar regultado, cambiar regla, aplicar match, comprobar, etc
}
