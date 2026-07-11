const revealElements = document.querySelectorAll('.reveal');

const revealObserver = new IntersectionObserver((entries) => {
  entries.forEach((entry) => {
    if (entry.isIntersecting) {
      entry.target.classList.add('is-visible');
      revealObserver.unobserve(entry.target);
    }
  });
}, {
  threshold: 0.18,
});

revealElements.forEach((revealElement) => {
  revealObserver.observe(revealElement);
});

const tiltCards = document.querySelectorAll('.tilt-card');

tiltCards.forEach((tiltCardElement) => {
  tiltCardElement.addEventListener('mousemove', (mouseEvent) => {
    const cardBounds = tiltCardElement.getBoundingClientRect();
    const relativeX = mouseEvent.clientX - cardBounds.left;
    const relativeY = mouseEvent.clientY - cardBounds.top;
    const rotateY = ((relativeX / cardBounds.width) - 0.5) * 10;
    const rotateX = (0.5 - (relativeY / cardBounds.height)) * 10;

    tiltCardElement.style.transform = `perspective(1000px) rotateX(${rotateX}deg) rotateY(${rotateY}deg) translateY(-4px)`;
  });

  tiltCardElement.addEventListener('mouseleave', () => {
    tiltCardElement.style.transform = 'perspective(1000px) rotateX(0deg) rotateY(0deg) translateY(0)';
  });
});

const floatingCardElement = document.querySelector('.floating-card');

if (floatingCardElement) {
  let floatAngle = 0;

  const animateFloatingCard = () => {
    floatAngle += 0.015;
    const translateY = Math.sin(floatAngle) * -8;
    floatingCardElement.style.transform = `translateY(${translateY}px)`;
    window.requestAnimationFrame(animateFloatingCard);
  };

  window.requestAnimationFrame(animateFloatingCard);
}

const floatingContactWidgetElement = document.querySelector('.floating-contact-widget');
const floatingContactToggleElement = document.getElementById('floatingContactToggle');

if (floatingContactWidgetElement && floatingContactToggleElement) {
  const setFloatingContactOpenState = (shouldOpen) => {
    floatingContactWidgetElement.classList.toggle('is-open', shouldOpen);
    floatingContactToggleElement.setAttribute('aria-expanded', shouldOpen ? 'true' : 'false');
  };

  floatingContactToggleElement.addEventListener('click', () => {
    const isCurrentlyOpen = floatingContactWidgetElement.classList.contains('is-open');
    setFloatingContactOpenState(!isCurrentlyOpen);
  });

  document.addEventListener('click', (clickEvent) => {
    if (!floatingContactWidgetElement.contains(clickEvent.target)) {
      setFloatingContactOpenState(false);
    }
  });

  document.addEventListener('keydown', (keyboardEvent) => {
    if (keyboardEvent.key === 'Escape') {
      setFloatingContactOpenState(false);
    }
  });
}
