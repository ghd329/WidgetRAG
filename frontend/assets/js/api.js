// 백엔드 API 기본 URL - 전체 페이지 공통, 절대 페이지별로 따로 선언하지 말 것
const BACKEND_BASE = "http://localhost:8080";

const mockApi={
  products:[
    {name:'반팔 티셔츠',price:'19,900원',category:'의류',desc:'기본 면 티셔츠'},
    {name:'러닝화',price:'59,000원',category:'신발',desc:'가벼운 러닝화'}
  ],
  questions:[
    {q:'배송은 얼마나 걸리나요?',time:'5분 전',status:'답변 완료'},
    {q:'교환 가능한가요?',time:'12분 전',status:'확인 필요'}
  ]
};