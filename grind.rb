#!/usr/bin/ruby
require "github_api"
require "mongo"
require "date"
require 'net/smtp'
require 'rest-client'
require 'json'

class GrindReport
	include Mongo
	
	def initialize
		@token = ENV["GITHUB_TOKEN"]
		@user = ENV["GITHUB_USER"]
		@repo = ENV["GITHUB_REPO"]
		@org = ENV["GITHUB_ORG"]
		@dbhost = ENV["MONGO_HOST"]
		@dbport = ENV["MONGO_PORT"]
		@dbname = ENV["MONGO_DBNAME"]
		@mailgunKey = ENV["MAILGUN_API_KEY"]
		@mailgunDomain = ENV["MAILGUN_DOMAIN"]
		@mailgunFrom = ENV["MAILGUN_FROM"]
	
		@github = Github.new(oauth_token:@token, user:@user, repo:@repo, org:@org)
		@db = MongoClient.new(@dbhost, @dbport).db(@dbname)
	end
	
	def sendRecap(interval=86400, user=nil) # 86400 = 24 hours in seconds
		issuesByMilestone = {}

		issues = @db["issues"].find().to_a
		
		if user then
			people = [user]
		else
			people = @db["people"].find().to_a
		end
		
		issues.each do |issue|
			next unless dateStringInInterval(issue["updated_at"], interval)
			if issue["milestone"] then
				issuesByMilestone[issue["milestone"]["title"]] ||= {}
				milestone = issuesByMilestone[issue["milestone"]["title"]]
				cat = getIssueCategory(issue, interval)
				milestone[cat] ||= []
				milestone[cat].push(issue)
			end
		end
		
		report = renderReport(issues, issuesByMilestone)
		people.each do |person|
			puts "Sending to #{person['email']} (@#{person['login']})"
			personalReport = report.sub("___PERSONAL_SECTION___", renderPersonal(person["login"], issues))
			puts personalReport
			sendEmail("Daily grind report", personalReport, [person["email"]])
		end
	end
	
	def renderReport(issues, issuesByMilestone)
		milestoneData = @github.issues.milestones.list("acres4", "documentation")
		s = "<html><head><style>#{stylesheet}</style></head><body><h1>Grind report for #{Time.now.strftime('%A, %B %e')}</h1>\n"
		milestoneActivityCounts = milestoneData.inject([]) { |counts, milestone| counts.push({ milestone:milestone, count:eventsForMilestone(issuesByMilestone[milestone.title])})}
		milestoneActivityCounts.sort! { |a, b| b[:count] <=> a[:count] }
		milestoneActivityCounts.each do |milestoneCount|
			milestone = milestoneCount[:milestone]
			s += renderMilestone(milestone, issuesByMilestone[milestone.title], issues)
		end
		
		s += renderOrphanedIssues(issues)
		
		s += renderWorkload(issues)
		
		s += "___PERSONAL_SECTION___\n"
		
		s += "</body></html>"
		
		return s
	end
	
	def renderWorkload(issues)
		issueCountsByAssignee = {}
		openIssues = issues.select { |issue| issue["state"] == "open" }
		openIssues.each do |issue|
			next unless issue["assignee"] && issue["assignee"]["login"]
			user = issue["assignee"]["login"]
			issueCountsByAssignee[user] = 0 unless issueCountsByAssignee[user]
			issueCountsByAssignee[user] += 1
		end
		
		issueCounts = []
		issueCountsByAssignee.each do |assignee, count|
			issueCounts.push({'assignee'=>assignee, 'count'=>count})
		end
		
		issueCounts.sort! { |a, b| b["count"] <=> a["count"] }
		
		s = ""
		s += "<div class=\"workload\">"
		s += "<h1>Workload</h1>\n"
		s += "<p>This is a breakdown of how many open issues each assignee has across all projects.</p>"
		s += "<ul>\n"
		issueCounts.each { |line|
			percentage = (100.0*line["count"]/openIssues.length).round(0)
			s += "<li><span class=\"user\">#{line['assignee']}</span>: <span class=\"count\">#{line['count']}</span> open issue#{line['count'] == 1 ? '' : 's'} (<span class=\"percentage\">#{percentage}%</span>)</li>\n"
		}
		s += "</ul>\n"
		
		return s
	end
	
	def renderPersonal(login, issues)
		opened = []
		s = "<div class=\"personal\">\n"
		s += "<h1>Now Let's Talk About You, <a href=\"https://github.com/#{login}\">#{login}</a></h1>\n"
		
		openIssues = issues.select { |issue| issue["state"] == "open" }
		openIssues.sort! { |a, b| b["updated_at"] <=> a["updated_at"] }
		
		assigned = openIssues.select do |issue|
			issue["assignee"] && issue["assignee"]["login"] == login
		end
		
		mentioning = openIssues.select do |issue|
			(issue["events"].index { |event| event["actor"]["login"] == login && event["event"] == "mentioned" }) != nil
		end
		
		opened = openIssues.select do |issue|
			issue["user"] && issue["user"]["login"] == login
		end
		
		s += "<div class=\"section assigned\">\n"
		s += "<h2>Issues assigned to you (<span class=\"count\">#{assigned.count}</span>)</h2><ul class=\"issues\">\n"
		assigned.each { |issue| s += renderIssueLine(issue) }
		s += "</ul></div>\n"
		s += "<div class=\"section mentioning\">\n"
		s += "<h2>Issues mentioning you (<span class=\"count\">#{mentioning.count}</span>)</h2><ul class=\"issues\">\n"
		mentioning.each { |issue| s += renderIssueLine(issue) }
		s += "</ul></div>\n"
		s += "<div class=\"section opened\">\n"
		s += "<h2>Issues opened by you (<span class=\"count\">#{opened.count}</span>)</h2><ul class=\"issues\">\n"
		opened.each { |issue| s += renderIssueLine(issue) }
		s += "</ul></div>\n"

		s += "</div>\n"
		
		return s
	end
	
	def renderOrphanedIssues(issues)
		orphanedIssues = []
		issues.each do |issue|
			next unless issue['state'] == 'open' # closed issues are not orphans
			
			# all issues must have milestones
			if not issue['milestone'] then
				orphanedIssues.push({'issue'=>issue, 'reason'=>'No milestone'})
				next
			end
			
			# all issues must have assignees
			if not issue['assignee'] then
				orphanedIssues.push({'issue'=>issue, 'reason'=>'No assignee'})
				next
			end
			
			# all issues must have at least one of these mandatory labels
			mandatoryLabels = ['active', 'resolved', 'code complete']
			labeled = false
			issue['labels'].each do |label|
				if mandatoryLabels.include? label["name"] then
					labeled = true
					break
				end
			end
			
			unless labeled then
				orphanedIssues.push({'issue'=>issue, 'reason'=>'Needs status label'})
			end
		end
		
		orphanedIssues.sort! { |a,b| a['issue']['user']['login'] <=> b['issue']['user']['login'] }
		
		s = ""
		s += "<div class=\"orphaned\">\n"
		s += "<h1>Orphaned Issues</h1>\n"
		s += "<p>The following issues might be hard to find in Github, since they either lack milestones, assignees or proper status tracking labels.</p>\n"
		s += "<ul class=\"issues\">\n"
		orphanedIssues.each { |line|
			issue = line['issue']
			s += "<li class=\"issue orphan\"><a href=\"#{issue['html_url']}\">\##{issue['number']}</a>: #{issue['title']} <span class=\"orphanReason\">#{line['reason']}</span> <span class=\"author\">#{issue['user']['login']}</span></li>\n"

		}
		s += "</ul>\n"
	end
	
	def renderIssueLine(issue)
		if issue['labels'].length > 0 then
			labels = (issue['labels'].inject([]) { |a, label| a.push(label["name"])}).join(", ")
		else
			labels = "no labels"
		end
		
		classes = [ "issue" ]
		classes.push "active" if dateStringInInterval(issue["updated_at"], 86400)
		milestone = issue['milestone'] ? issue['milestone']['title'] : 'No milestone'
		"<li class=\"#{classes.join(' ')}\"><a href=\"#{issue['html_url']}\">\##{issue['number']}</a>: #{issue['title']} <span class=\"labels\">(<i>#{labels}</i>)</span> <span class=\"milestoneTag\">[<i>#{milestone}</i>]</span></li>\n"
	end
	
	def eventsForMilestone(milestone)
		return 0 unless milestone
		s = 0
		milestone.each { |k, v| s += milestone[k].length }
		return s
	end
	
	def issueHasLabel?(issue, labelName)
		return false unless issue["labels"]
		issue["labels"].select do |label|
			return true if label["name"] == labelName
		end
		
		return false
	end
	
	def renderMilestone(milestone, activeIssues, issues)
		openIssues = issues.select { |issue| issue["state"] == "open" && issue["milestone"] && issue["milestone"]["title"] == milestone.title }
		resolvedIssues = openIssues.select { |issue| issueHasLabel?(issue, "resolved") }
		numResolved = resolvedIssues.length
		percentageResolved = (100.0*numResolved/(milestone.open_issues+milestone.closed_issues)).round(0)
		percentageClosed = (100.0*milestone.closed_issues/(milestone.open_issues+milestone.closed_issues)).round(0)
		
		s = "<div class=\"milestone\"><h2><a href=\"https://github.com/#{@user}/#{@repo}/issues?milestone=#{milestone.number}&state=open\">#{milestone.title}</a>, #{percentageClosed}%</h2>\n"
		s += "<p class=\"overall_class\"><b>#{milestone.open_issues}</b> open, <b>#{milestone.closed_issues}</b> closed, <b>#{numResolved}</b> resolved</p>\n"
		s += "<div class=\"meter\"><span class=\"closed\" style=\"width:#{percentageClosed}%\"></span><span class=\"resolved\" style=\"width:#{percentageResolved}%\"></span></div>"
		
		if activeIssues then
			s += renderMilestoneIssues(activeIssues, "new")
			s += renderMilestoneIssues(activeIssues, "reopened")
			s += renderMilestoneIssues(activeIssues, "active")
			s += renderMilestoneIssues(activeIssues, "resolved")
			s += renderMilestoneIssues(activeIssues, "closed")
		else
			s += "<p class=\"no_activity\"><i>No activity today.</i></p>\n"
		end
		s += "</div>\n"
		return s
	end
	
	def renderMilestoneIssues(milestone, section)
		s = "<h3>#{section.capitalize}</h3>\n<ul class=\"issues\">"
		return "" unless milestone[section]
		milestone[section].each { |issue| s += renderIssueLine(issue) }		
		s += "</ul>\n"
		
		return s
	end
	
	def getIssueCategory(issue, interval)
		if(issue["state"] == "open") then
			return "resolved" if issueAddedLabelInInterval(issue, "resolved", interval)
			return "new" if dateStringInInterval(issue["created_at"], interval)
			return "reopened" if issueHasEventInInterval(issue, "reopened", interval)
		else
			return "closed" if dateStringInInterval(issue["closed_at"], interval)
		end
		
		return "active"
	end
	
	def dateStringInInterval(dateStr, interval)
		now = Time.now
		date = DateTime.parse(dateStr).to_time
		return now - date <= interval
	end

	def issueAddedLabelInInterval(issue, labelName, interval)
		issue["labelEvents"].each do |event|
			next unless event["action"] == "added"
			next unless event["label"]["name"] == labelName
			return true if dateStringInInterval(event["date"], interval)
		end
		
		return false
	end
	
	def issueHasEventInInterval(issue, eventType, interval)
		issue["events"].each do |event|
			next unless event["event"] == eventType
			return true if dateStringInInterval(event["created_at"], interval)
		end
		
		return false
	end
	
	def sendEmail(subject, body, recipients)
		url = "https://api:#{@mailgunKey}@api.mailgun.net/v2/#{@mailgunDomain}/messages"
		RestClient.post url,
			:from => @mailgunFrom,
			:to => recipients.join(", "),
			:subject => subject,
			:html => body
	end
	
	def stylesheet
		 <<CSS_END
@import url(http://fonts.googleapis.com/css?family=Roboto+Slab:300,400,700);
@import url(http://fonts.googleapis.com/css?family=Open+Sans:300);

body {
    font-family:"Open Sans", sans-serif;
    background-color:#fff;
}

h1 {
    font-family:"Roboto Slab", serif;
    font-weight:400;
    color:#111;
}

.milestone {
background: rgb(245,245,245); /* Old browsers */
background: -moz-linear-gradient(top,  rgba(245,245,245,1) 0%, rgba(242,242,242,1) 50%, rgba(239,239,239,1) 51%, rgba(255,255,255,1) 100%); /* FF3.6+ */
background: -webkit-gradient(linear, left top, left bottom, color-stop(0%,rgba(245,245,245,1)), color-stop(50%,rgba(242,242,242,1)), color-stop(51%,rgba(239,239,239,1)), color-stop(100%,rgba(255,255,255,1))); /* Chrome,Safari4+ */
background: -webkit-linear-gradient(top,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* Chrome10+,Safari5.1+ */
background: -o-linear-gradient(top,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* Opera 11.10+ */
background: -ms-linear-gradient(top,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* IE10+ */
background: linear-gradient(to bottom,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* W3C */
filter: progid:DXImageTransform.Microsoft.gradient( startColorstr='#f5f5f5', endColorstr='#ffffff',GradientType=0 ); /* IE6-9 */


    -moz-border-radius: 15px;
    border-radius: 15px;
    border: 1px solid #eee;
    
    padding: 0 10px 0 10px;
    margin-bottom:20px;
}

.milestone h2 {
    font-family:"Roboto Slab", serif;
    font-weight:300;
    color:#000;
    margin-top:0;
    padding-top:0;
    padding-bottom:0;
    margin-bottom:0;
}

.milestone h3 {
    font-family:"Roboto Slab", serif;
    color:#015C65;
    padding-bottom:0;
    margin-bottom:0;
}

.milestone span.milestoneTag {
    display:none
}

h3 a {
    color:#FF0D00;
}

h2 a {
    color:#FF0D00;
}

h1 a {
    color:#FF0D00;
}

.milestone p a {
    font-family:"Roboto Slab",serif;
    font-weight:300;
    color:#639A00
}

.milestone p a:visited {
    color:#639A00
}

p.overall_count {
    margin-top:0;
    padding-top:0;
}

.overall_count b {
    color:#015C65;
    font-size:120%;
}

ul.issues {
    list-style-type: none;
    margin-top:0;
    padding: 0px 10px 0px 10px;
}

ul.issues a {
    color:#639A00;
}

ul.issues span.author {
	color:black;
	font-weight:bold;
}

p.issues i {
    color:#aaa;
    font-size:80%;
}

.stanza {
    font-family:"Roboto Slab",serif;
    font-style:italic;
    font-size:8px;
    color:#aaa;
}

.personal h2 {
    font-family:"Roboto Slab", serif;
    font-weight:300;
    color:#000;
}

.personal li {
    color:#777;
}

.personal li.active {
    color:#000;
}

.personal span.milestoneTag {
    font-weight:bold;
}

.personal span.milestoneTag i {
    font-style:normal;
}

.section h2 {
    margin-bottom:0;
    color:#015C65;
}
.section ul {
    margin-top: 0;
    padding-top: 0;
}

.section h2 span.count {
    color:#000;
    font-weight:700;
}

.workload ul {
    list-style-type: none;
    margin-top:0;
    padding: 0px 10px 0px 10px;
}

.workload span.user {
    font-weight:bold;
    color:black;
}

.workload span.count {
    font-size:120%;
    color:#015C65;
}

.workload span.percentage {
    font-size:120%;
    color:#639A00;
}

li.orphan span.orphanReason {
    color:#999;
}

.meter { 
	height: 20px;  /* Can be anything */
	position: relative;
	background: #555;
	-moz-border-radius: 25px;
	-webkit-border-radius: 25px;
	border-radius: 25px;
	padding: 10px;
	-webkit-box-shadow: inset 0 -1px 1px rgba(255,255,255,0.3);
	-moz-box-shadow   : inset 0 -1px 1px rgba(255,255,255,0.3);
	box-shadow        : inset 0 -1px 1px rgba(255,255,255,0.3);
}

.meter > span {
	display: block;
	height: 100%;
	   -webkit-border-top-right-radius: 8px;
	-webkit-border-bottom-right-radius: 8px;
	       -moz-border-radius-topright: 8px;
	    -moz-border-radius-bottomright: 8px;
	           border-top-right-radius: 8px;
	        border-bottom-right-radius: 8px;
	    -webkit-border-top-left-radius: 20px;
	 -webkit-border-bottom-left-radius: 20px;
	        -moz-border-radius-topleft: 20px;
	     -moz-border-radius-bottomleft: 20px;
	            border-top-left-radius: 20px;
	         border-bottom-left-radius: 20px;
	background-color: rgb(43,194,83);
	background-image: -webkit-gradient(
	  linear,
	  left bottom,
	  left top,
	  color-stop(0, rgb(43,194,83)),
	  color-stop(1, rgb(84,240,84))
	 );
	background-image: -webkit-linear-gradient(
	  center bottom,
	  rgb(43,194,83) 37%,
	  rgb(84,240,84) 69%
	 );
	background-image: -moz-linear-gradient(
	  center bottom,
	  rgb(43,194,83) 37%,
	  rgb(84,240,84) 69%
	 );
	background-image: -ms-linear-gradient(
	  center bottom,
	  rgb(43,194,83) 37%,
	  rgb(84,240,84) 69%
	 );
	background-image: -o-linear-gradient(
	  center bottom,
	  rgb(43,194,83) 37%,
	  rgb(84,240,84) 69%
	 );
	-webkit-box-shadow: 
	  inset 0 2px 9px  rgba(255,255,255,0.3),
	  inset 0 -2px 6px rgba(0,0,0,0.4);
	-moz-box-shadow: 
	  inset 0 2px 9px  rgba(255,255,255,0.3),
	  inset 0 -2px 6px rgba(0,0,0,0.4);
	position: relative;
	overflow: hidden;
    float:left;
}

.meter > span.closed {
    background-color: #f1a165; 
background-image: -webkit-gradient(linear, 0 0, 0 100%, from(#86d000), to(#639a00));
background-image: -webkit-linear-gradient(#86d000, #639a00);
background-image: -moz-linear-gradient(#86d000, #639a00);
background-image: -o-linear-gradient(#86d000, #639a00);
background-image: linear-gradient(#86d000, #639a00);
}

.meter > span.resolved {
    	background-color: #02a6b6;
    	background-image: -webkit-gradient(linear,left top,left bottom,color-stop(0, #02a6b6),color-stop(1, #015c65));
	background-image: -webkit-linear-gradient(top, #02a6b6, #015c65); 
        background-image: -moz-linear-gradient(top, #02a6b6, #015c65);
        background-image: -ms-linear-gradient(top, #02a6b6, #015c65);
        background-image: -o-linear-gradient(top, #02a6b6, #015c65);
    	    -webkit-border-top-left-radius: 0px;
	 -webkit-border-bottom-left-radius: 0px;
	        -moz-border-radius-topleft: 0px;
	     -moz-border-radius-bottomleft: 0px;
	            border-top-left-radius: 0px;
	         border-bottom-left-radius: 0px;
}

.meter > span:after {
	content: "";
	position: absolute;
	top: 0; left: 0; bottom: 0; right: 0;
	background-image: 
	   -webkit-gradient(linear, 0 0, 100% 100%, 
	      color-stop(.25, rgba(255, 255, 255, .2)), 
	      color-stop(.25, transparent), color-stop(.5, transparent), 
	      color-stop(.5, rgba(255, 255, 255, .2)), 
	      color-stop(.75, rgba(255, 255, 255, .2)), 
	      color-stop(.75, transparent), to(transparent)
	   );
	background-image: 
		-webkit-linear-gradient(
		  -45deg, 
	      rgba(255, 255, 255, .2) 25%, 
	      transparent 25%, 
	      transparent 50%, 
	      rgba(255, 255, 255, .2) 50%, 
	      rgba(255, 255, 255, .2) 75%, 
	      transparent 75%, 
	      transparent
	   );
	background-image: 
		-moz-linear-gradient(
		  -45deg, 
	      rgba(255, 255, 255, .2) 25%, 
	      transparent 25%, 
	      transparent 50%, 
	      rgba(255, 255, 255, .2) 50%, 
	      rgba(255, 255, 255, .2) 75%, 
	      transparent 75%, 
	      transparent
	   );
	background-image: 
		-ms-linear-gradient(
		  -45deg, 
	      rgba(255, 255, 255, .2) 25%, 
	      transparent 25%, 
	      transparent 50%, 
	      rgba(255, 255, 255, .2) 50%, 
	      rgba(255, 255, 255, .2) 75%, 
	      transparent 75%, 
	      transparent
	   );
	background-image: 
		-o-linear-gradient(
		  -45deg, 
	      rgba(255, 255, 255, .2) 25%, 
	      transparent 25%, 
	      transparent 50%, 
	      rgba(255, 255, 255, .2) 50%, 
	      rgba(255, 255, 255, .2) 75%, 
	      transparent 75%, 
	      transparent
	   );
	z-index: 1;
	-webkit-background-size: 50px 50px;
	-moz-background-size:    50px 50px;
	background-size:         50px 50px;
	-webkit-animation: move 2s linear infinite;
	   -webkit-border-top-right-radius: 8px;
	-webkit-border-bottom-right-radius: 8px;
	       -moz-border-radius-topright: 8px;
	    -moz-border-radius-bottomright: 8px;
	           border-top-right-radius: 8px;
	        border-bottom-right-radius: 8px;
	    -webkit-border-top-left-radius: 20px;
	 -webkit-border-bottom-left-radius: 20px;
	        -moz-border-radius-topleft: 20px;
	     -moz-border-radius-bottomleft: 20px;
	            border-top-left-radius: 20px;
	         border-bottom-left-radius: 20px;
	overflow: hidden;
}
CSS_END

	end
end

if ARGV.length == 2
	user = { 'login'=>ARGV[0], 'email'=>ARGV[1] }
	print "Reporting for Github user #{user['login']} (email: #{user['email']})\n"
else
	user = nil
end

grind = GrindReport.new
grind.sendRecap(86400, user)
