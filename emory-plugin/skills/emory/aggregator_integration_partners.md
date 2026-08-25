# Aggregators & Integration Partners (case-intake reference)

Every rating / eContract request into Safe-Guard arrives through an **Aggregator** (the
middleware that connects to SGI's API) and originates from an **Integration Partner** (the
menu / digital-retail / DMS tool the dealer actually used). When filling out a case, capture
**both** — they scope where an API-layer problem lives once the config checks (dealer /
product / forms / rates / classing) all PASS. If everything is configured correctly and the
request still fails, the issue is at the aggregator or integration-partner layer → route to
**Middleware / the aggregator**, naming the partner.

Three aggregators: **F&I Express**, **PCMI Corporation** (PCRS), **Provider Exchange Network (PEN)**.

> A partner name in a payload may not be exact — normalize against the lists below. Many
> partners route through **more than one** aggregator (see "Dual-routed" note), so confirm the
> aggregator from the request itself, not just from the partner name.

## F&I Express — Integration Partners
AppOne · Car Capital Corp · Certified Dealers Process · Chapman Auto Group Digital Retailing System ·
Credit IQ · D&M Leasing (Hernco) · Deal Central (Retail 360) · Dealer Inspire · DealerOn ·
Drivethru Labs · eLeader Tech (Express Menu) / Ibarra Brito Group, Inc. · Ethos Menu · Fast Avenue ·
Intice · Line5 · OptionSoft/Oti Services · Pearl Technology Holdings · PIN Solutions · Vizicar ·
Web Finance Direct · Xpress Credit · A2Z Sync · Accelerate Deal 360 (Cox Auto) · ASN Software ·
AutoFI · Automatrix DMS · BMW Tier 1 ConfigureYourOwn (CYO) · Capital One · CarNow · Darwin Menu ·
Darwin Online · Dealer eProcess · DealerCenter / NowCom · DealerSocket · Dealertrack uniFI ·
Digital Motors · Esntial Commerce (Cox Auto DR) · Express Aftermarket (F&I Express) ·
Fuse Auto Tech, LLC. · Gubagoo · Impact Group/Fusion · Jely.io · MenuMetric · Roadster ·
StoneEagle F&I · TagRail · tecAssured · Tekion ARC

## PCMI Corporation — Integration Partners
PCRS

## Provider Exchange Network (PEN) — Integration Partners
AcceleFI · AGWS Menu · APC Integrated Services · AppOne · Atlantic Coast Management · AutoFI ·
Automotive Innovations / OpsVision / SmartChoice Menu · Caramel · CarChex · CarFluent ·
CarmaCare (My Carma Care) · Caroogo (ePulseTrak) · Certified Dealers Process · DCS Software ·
DealerMall · ForeverCar · GM Tier 1 Shop.Click.Drive · IFS · InLine Data Systems · Joydrive ·
Lithia Driveway · Matador AI · MB Digital · One Touch System DMS · OpLogic CRM · Otoz Mobility ·
OttoMoto · PBS Systems Group · Reynolds and Reynolds · Route66 RV · Service Lane eAdvisor ·
Skywerks DMS · Sonic · TagRail · Toyota Service Lane App / Toyota Smart Path · Upstart ·
Acura Digital Revolution · A2Z Sync · AutoSoftGO · CarGurus · Darwin Menu · Darwin Online ·
Dealer eProcess · DeskIt / DealerCorp · Dialog Direct · DocuPad · Gubagoo · IAS SmartMenu ·
Impact Group/Fusion · iTap Menu · Line5 · RouteOne Menu / MaximTrak · MenuMax · MenuMetric ·
MenuSys · MenuVantage Platinum · Modal · OptionSoft/Oti Services · Process Pro ·
Prodigy Software Inc. / Upstart · Roadster · RouteOne (also RT1 F&I Tool) · StoneEagle F&I ·
tecAssured · Tekion ARC · VisionMenu

## Dual-routed partners (appear under BOTH F&I Express and PEN)
A2Z Sync · AppOne · AutoFI · Certified Dealers Process · Darwin Menu · Darwin Online ·
Dealer eProcess · Gubagoo · Impact Group/Fusion · Line5 · MenuMetric · OptionSoft/Oti Services ·
Roadster · StoneEagle F&I · TagRail · tecAssured · Tekion ARC

For these, the **partner name alone does not tell you the aggregator** — read it off the request
(getProductsSGI / wsGetRatesByRest / saveEContract source), and record the specific aggregator +
partner pair in the case.
