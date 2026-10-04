(async () => {
  const net = s => (s || '').replace(/\s+/g, ' ').trim();
  const pause = ms => new Promise(r => setTimeout(r, ms));
  const out = { url: location.href };
  try {
    const ld = JSON.parse(document.querySelector('script[type="application/ld+json"]').textContent);
    out.nom = ld.name; out.description = ld.description;
    if (ld.address) out.adresse = ld.address.streetAddress;
    if (ld.aggregateRating) { out.note = parseFloat(ld.aggregateRating.ratingValue); out.avis = parseInt(ld.aggregateRating.reviewCount, 10); }
    out.image = ld.image;
  } catch (e) {}
  let A = null;
  try { A = JSON.parse(document.querySelector('script[data-capla-store-data="apollo"]').textContent); } catch (e) {}
  const R = o => (o && o.__ref && A) ? A[o.__ref] : o;
  if (A) {
    const P = A[Object.keys(A).find(k => k.startsWith('Property:'))] || {};
    if (P.name) out.nom = P.name;
    const sr = A['StarRating:{}']; if (sr && sr.value) out.etoiles = sr.value;
    const bpk = Object.keys(A).find(k => k.startsWith('BasicPropertyData:'));
    if (bpk && A[bpk].location) { const L = A[bpk].location; out.adresse = L.formattedAddress || out.adresse; out.ville = L.city; out.lat = L.latitude; out.lng = L.longitude; }
    const pr = A['PropertyReview:{}']; if (pr && pr.totalScore) { out.note = pr.totalScore.score; out.avis = pr.totalScore.reviewsCount; }
    const tr = A['HotelTranslation:{}']; if (tr && tr.description) out.description = tr.description;
    const pt = R(P.accommodationType); if (pt && pt.type) out.type = pt.type;
    const pol = A['PropertyPolicies:{}']; if (pol && pol.pets) out.animaux = [pol.pets.petsAllowed, pol.pets.chargeModePets];
    const cb = A['ChildAndBedPolicy:{}']; if (cb) out.enfants = { admis: cb.allowChildren, litsBebe: cb.allowCribs, litsAppoint: cb.allowExtraBeds, ageMin: cb.minChildrenAge };
    out.restauration = Object.keys(A).filter(k => k.startsWith('Cuisine:')).map(k => A[k].name);
    out.repas = Object.keys(A).filter(k => k.startsWith('OpenForMeal:')).map(k => A[k].name);
    out.cartes = Object.keys(A).filter(k => k.startsWith('AcceptedCreditCard:')).map(k => A[k].name);
    out.remontees = Object.keys(A).filter(k => k.startsWith('SkiLift:')).map(k => [A[k].name, A[k].localizedDistance]);
    const rq = A.ROOT_QUERY || {};
    Object.keys(rq).forEach(k => { const v = rq[k]; if (k.startsWith('hotelPageByPageName') && v && v.propertyFullExtended && v.propertyFullExtended.languagesSpoken) out.langues = v.propertyFullExtended.languagesSpoken.languageCodes; });
    const ch = [];
    Object.keys(A).filter(k => k.startsWith('RoomDetails:')).forEach(k => {
      const r = A[k], rd = A['RoomData:' + r.id];
      const eq = rd && rd.amenities ? rd.amenities.map(a => { const b = R(a); return b && b.instances ? b.instances.map(i => { const x = R(i); return x && x.title; }).filter(Boolean).join(', ') : ''; }).filter(Boolean) : [];
      const lits = (r.bedConfigurations || []).map(c => (c.beds || []).map(b => [b.count, b.bedType])).filter(x => x.length);
      ch.push({ nom: r.translations && r.translations.name, taille: r.roomSizeM2, lits, description: r.translations && r.translations.description, equipements: eq });
    });
    out.chambres = ch;
    // Tous les équipements connus de la page, regroupés par famille Booking
    const GR = { 1: 'Général', 2: 'Activités', 3: 'Services de réception', 4: 'Chambre', 5: 'Salle de bains', 6: 'Médias et technologies', 7: 'Restauration et boissons', 8: 'Services de ménage', 9: 'Services professionnels', 10: 'Boutiques', 11: 'Internet', 12: 'Cuisine', 13: 'Extérieur', 14: 'Vue', 15: 'Salon et espace de travail', 16: 'Parking', 17: 'Chambre', 19: 'Accessibilité', 20: 'Animaux', 21: 'Piscine et bien-être', 22: 'Sécurité', 23: 'Divertissement et services familles', 25: 'Transports', 39: 'Chambre' };
    const fam = {};
    Object.keys(A).filter(k => k.startsWith('BaseFacility:')).forEach(k => {
      const b = A[k]; const g = GR[b.groupId] || 'Autres';
      (b.instances || []).forEach(i => { const x = R(i); if (x && x.title) { const t = x.title.replace(/^\d+\.\s*/, ''); (fam[g] = fam[g] || new Set()).add(t); } });
    });
    out.equipementsTous = Object.keys(fam).map(g => ({ groupe: g, items: [...fam[g]] }));
    if (P.houseRules) {
      const h = P.houseRules, c = h.checkinCheckoutTimes || {};
      const t1 = c.checkinTimeRange || {}, t2 = c.checkoutTimeRange || {};
      out.arrivee = [t1.fromFormatted && 'À partir de ' + t1.fromFormatted, t1.untilFormatted && "jusqu'à " + t1.untilFormatted].filter(Boolean).join(' ');
      out.depart = [t2.fromFormatted && 'À partir de ' + t2.fromFormatted, t2.untilFormatted && "Jusqu'à " + t2.untilFormatted].filter(Boolean).join(' ');
      if (h.checkinAgeRestriction) out.ageMin = h.checkinAgeRestriction.minCheckinAge;
    }
    if (Array.isArray(P.finePrints)) out.aSavoir = P.finePrints.slice();
    if (Array.isArray(P.meals)) out.repasDetail = P.meals.map(m => ({ type: m.mealType, prix: m.price, horaires: m.attributes && m.attributes.openingTime ? m.attributes.openingTime.startTime + '–' + m.attributes.openingTime.endTime : '', style: m.attributes ? (m.attributes.style || []).join(', ') : '', note: m.attributes && m.attributes.foodScore ? m.attributes.foodScore.score : null }));
  }
  if (out.description) { const m = out.description.match(/(\d+)\s+(chambres|hébergements|logements|suites|rooms)/i); if (m) out.nbChambres = parseInt(m[1], 10); }
  // Fait défiler la page pour charger les sections affichées à la demande
  const h0 = document.body.scrollHeight;
  for (let y = 0; y < Math.max(h0, document.body.scrollHeight); y += 700) { window.scrollTo(0, y); await pause(90); }
  await pause(1500);
  const titre = t => [...document.querySelectorAll('h2,h3')].find(h => net(h.textContent).toLowerCase().includes(t));
  const bloc = h => h ? (h.closest('[data-testid="property-section--content"]') || h.parentElement.parentElement) : null;
  const sE = document.querySelector('[data-testid="property-facilities-block-container"]') || bloc(titre('équipements de l'));
  const groupes = [];
  if (sE) {
    sE.querySelectorAll('ul').forEach(ul => {
      if (ul.closest('[data-testid="property-most-popular-facilities-wrapper"]') || ul.closest('[data-testid="HouseRules-wrapper"]')) return;
      const lis = [...ul.children].filter(e => e.tagName === 'LI');
      if (!lis.length) return;
      let t = '', e = ul.previousElementSibling;
      if (e) t = net(e.innerText);
      if (!t && ul.parentElement && ul.parentElement.firstElementChild !== ul) t = net(ul.parentElement.firstElementChild.innerText);
      const items = lis.map(li => net(li.innerText)).filter(x => x && x.length < 120);
      if (items.length) groupes.push({ groupe: (t.split(/\n/)[0] || 'Autres').slice(0, 60), items });
    });
  }
  out.equipements = groupes.length ? groupes : (out.equipementsTous || []);
  const pop = document.querySelector('[data-testid="property-most-popular-facilities-wrapper"]');
  if (pop) { const li = [...pop.querySelectorAll('li')].map(x => net(x.innerText)).filter(Boolean); out.pointsForts = li.length ? li : pop.innerText.split('\n').map(net).filter(x => x && !/points forts/i.test(x)); }
  out.sousNotes = [...document.querySelectorAll('[data-testid="review-subscore"]')].map(e => { const s = net(e.innerText); const m = s.match(/^(.*?)\s+(\d{1,2}[,.]\d)\b/); return m ? [m[1].replace(/[,:]$/, ''), parseFloat(m[2].replace(',', '.'))] : null; }).filter(Boolean)
    .filter((x, i, a) => a.findIndex(y => y[0] === x[0]) === i);
  const hr = document.querySelector('[data-testid="HouseRules-wrapper"]');
  if (hr) {
    const lignes = hr.innerText.split('\n').map(net).filter(Boolean);
    out.regles = lignes.filter(l => !/consulter les dates|accepte les demandes sp/i.test(l)).slice(0, 80);
    const apres = k => { const i = lignes.findIndex(l => l.toLowerCase() === k); return i >= 0 ? lignes[i + 1] : ''; };
    out.arrivee = out.arrivee || apres('arrivée'); out.depart = out.depart || apres('départ');
  }
  const hS = titre('à savoir');
  if (hS) {
    let e = hS.parentElement, l = [];
    for (let i = 0; i < 7 && e; i++, e = e.parentElement) {
      if (e.querySelectorAll('h2').length > 1) break;
      l = e.innerText.split('\n').map(net).filter(x => x.length > 25 && !/informations essentielles|consulter les dates/i.test(x));
      if (l.length) break;
    }
    out.aSavoir = [...new Set([...(out.aSavoir || []), ...l])];
  }
  out.environs = [...document.querySelectorAll('[data-testid="poi-block"]')].map(b => { const l = b.innerText.split('\n').map(net).filter(Boolean); return { titre: l[0], lieux: l.slice(1) }; });
  return out;
})()
