module webbackend.apiemail;

struct ApiAttachment
{
    string Url;
    string ctype;
    string filename;
    string contentId;
    ulong  size;
}

struct ApiEmail
{
    string dbId;
    string from; 
    string to; 
    string cc; 
    string bcc; 
    string subject; 
    string isoDate; 
    string date; 
    string bodyHtml;
    string bodyPlain;
    bool deleted = false;
    ApiAttachment[] attachments; 
}
